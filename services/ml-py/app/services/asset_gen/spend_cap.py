"""Per-environment spend cap for asset generation (T-INFRA-040).

Acceptance criterion (AGENTS.md §11 / docs/07 T-INFRA-040): "exceeding the
budget cap halts generation and alerts rather than spending unbounded."

The cap sits at the :class:`~app.services.asset_gen.queue.AssetSubmissionService`
boundary, which is the single chokepoint every paid provider call passes
through (gRPC ``SubmitAsset`` and ``ReconcileManifest`` both go through it).
Charges are recorded *only* when a submission would actually publish a job
to the worker queue — dedup hits and dry-runs are free, by design, so a
healthy reconciler that finds everything READY does not consume spend.

This module exposes a small Protocol so production can swap a
counter-backed implementation for one backed by Redis / Postgres, but ships
a deterministic in-memory ``WindowedSubmissionCap`` that uses a real wall
clock and is fully exercised by the test suite.

Alerting is intentionally pluggable. The cap calls an injected
:data:`SpendCapAlertSink` exactly once per breach (until the window
rolls), so production wires it to PagerDuty / OpsGenie without this module
having to know how. Tests record the calls and assert the once-per-breach
contract.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Protocol, runtime_checkable

logger = logging.getLogger(__name__)


class AssetGenBudgetExceededError(Exception):
    """Raised by :meth:`SpendCap.charge` when the cap is hit.

    Carries machine-readable detail so the gRPC layer can surface
    ``RESOURCE_EXHAUSTED`` with a useful message and so telemetry can
    dashboard cap breaches per environment.
    """

    def __init__(
        self,
        message: str,
        *,
        environment: str,
        period_seconds: int,
        limit: int,
        usage: int,
    ) -> None:
        super().__init__(message)
        self.environment = environment
        self.period_seconds = period_seconds
        self.limit = limit
        self.usage = usage


@dataclass(frozen=True, slots=True)
class SpendUsage:
    """Snapshot of cap usage at one instant. Surfaced for observability."""

    environment: str
    limit: int
    used: int
    period_seconds: int
    window_started_at: datetime | None
    """When the current rolling window opened. ``None`` if no charges yet."""

    @property
    def remaining(self) -> int:
        """How many more submissions the cap will allow before the window
        rolls. ``-1`` when the cap is unlimited (``limit <= 0``)."""
        if self.limit <= 0:
            return -1
        return max(0, self.limit - self.used)


SpendCapAlertSink = Callable[["AssetGenBudgetExceededError"], None]
"""Callable invoked exactly once when the cap is first breached in a window.

Production wires this to PagerDuty / OpsGenie. The default sink emits a
single ``CRITICAL`` log line so a missing wire is still loud."""


def _default_alert_sink(exc: AssetGenBudgetExceededError) -> None:
    logger.critical(
        "asset_gen.spend_cap.breached",
        extra={
            "environment": exc.environment,
            "period_seconds": exc.period_seconds,
            "limit": exc.limit,
            "usage": exc.usage,
        },
    )


@runtime_checkable
class SpendCap(Protocol):
    """Submission-boundary cap. Implementations must be thread-safe."""

    def charge(self) -> None:
        """Record one chargeable submission.

        Raises:
            AssetGenBudgetExceededError: when the cap has been hit. The
                charge does not stick when this raises — usage is not
                advanced past the limit.
        """
        ...

    def usage(self) -> SpendUsage: ...


class NoSpendCap:
    """Default no-op cap. Used when the env declares no limit."""

    environment: str = "unlimited"

    def charge(self) -> None:
        return

    def usage(self) -> SpendUsage:
        return SpendUsage(
            environment=self.environment,
            limit=0,
            used=0,
            period_seconds=0,
            window_started_at=None,
        )


class WindowedSubmissionCap:
    """Counts chargeable submissions in a rolling time window.

    The window opens on the first charge and rolls forward when the next
    charge arrives after ``window_started_at + period``. Within a window,
    ``limit`` chargeable submissions are allowed; submission ``limit + 1``
    raises :class:`AssetGenBudgetExceededError` and invokes the alert sink
    exactly once per window.

    The clock is injectable so tests are deterministic; production passes
    :func:`datetime.now`.
    """

    def __init__(
        self,
        *,
        environment: str,
        limit: int,
        period_seconds: int,
        clock: Callable[[], datetime],
        alert_sink: SpendCapAlertSink | None = None,
    ) -> None:
        if not environment:
            raise ValueError("environment must be set")
        if limit <= 0:
            raise ValueError("limit must be positive (use NoSpendCap for unlimited)")
        if period_seconds <= 0:
            raise ValueError("period_seconds must be positive")
        self.environment = environment
        self._limit = limit
        self._period = timedelta(seconds=period_seconds)
        self._clock = clock
        self._sink = alert_sink or _default_alert_sink
        self._lock = threading.Lock()
        self._used = 0
        self._window_started_at: datetime | None = None
        self._alerted_this_window = False

    def charge(self) -> None:
        with self._lock:
            now = self._clock()
            self._roll_if_needed(now)
            if self._used >= self._limit:
                exc = AssetGenBudgetExceededError(
                    (
                        f"asset-gen submission cap reached for {self.environment}: "
                        f"{self._used}/{self._limit} in last {int(self._period.total_seconds())}s"
                    ),
                    environment=self.environment,
                    period_seconds=int(self._period.total_seconds()),
                    limit=self._limit,
                    usage=self._used,
                )
                # Alert once per window so a sustained breach does not
                # spam pages but a re-opened window re-alerts.
                if not self._alerted_this_window:
                    self._alerted_this_window = True
                    try:
                        self._sink(exc)
                    except Exception:
                        logger.exception("asset_gen.spend_cap.alert_sink_failed")
                raise exc
            if self._window_started_at is None:
                self._window_started_at = now
            self._used += 1

    def usage(self) -> SpendUsage:
        with self._lock:
            now = self._clock()
            self._roll_if_needed(now)
            return SpendUsage(
                environment=self.environment,
                limit=self._limit,
                used=self._used,
                period_seconds=int(self._period.total_seconds()),
                window_started_at=self._window_started_at,
            )

    def _roll_if_needed(self, now: datetime) -> None:
        if self._window_started_at is None:
            return
        if now - self._window_started_at >= self._period:
            self._window_started_at = None
            self._used = 0
            self._alerted_this_window = False


def build_spend_cap_from_env(env: dict[str, str]) -> SpendCap:
    """Construct a cap from the standard env vars.

    Recognised:

    - ``ECHO_ENV``                       — environment label (``dev`` default).
    - ``ECHO_ASSET_GEN_PERIOD_SECONDS``  — rolling window length. Default ``3600`` (1 hour).
    - ``ECHO_ASSET_GEN_PERIOD_CAP``      — max chargeable submissions per
      window. ``0`` (the default) means unlimited and returns
      :class:`NoSpendCap`.

    Production sets the cap; CI / dev leave it unset and get
    :class:`NoSpendCap`, so this module is invisible until opted into.
    """
    try:
        limit = int(env.get("ECHO_ASSET_GEN_PERIOD_CAP", "0") or 0)
    except ValueError as exc:
        raise ValueError("ECHO_ASSET_GEN_PERIOD_CAP must be an integer") from exc
    if limit <= 0:
        return NoSpendCap()
    try:
        period = int(env.get("ECHO_ASSET_GEN_PERIOD_SECONDS", "3600") or 3600)
    except ValueError as exc:
        raise ValueError("ECHO_ASSET_GEN_PERIOD_SECONDS must be an integer") from exc
    environment = env.get("ECHO_ENV", "dev") or "dev"
    from datetime import UTC

    return WindowedSubmissionCap(
        environment=environment,
        limit=limit,
        period_seconds=period,
        clock=lambda: datetime.now(UTC),
    )
