"""Continuous reconciler / scheduler for 3D assets (T-ML-052).

The reconciler converges the *world* toward its desired state: given the
assets a Season declares in its manifest (the desired set) and the assets
already known to the metadata repository (the ready / in-flight set), it
enqueues exactly the missing or stale ones — never re-running work that is
already done or already queued.

Properties (the T-ML-052 acceptance criteria):

- **Diff, don't regenerate.** With N desired and M already READY, exactly
  N - M jobs are enqueued (assuming the rest are neither in-flight nor
  failed). READY assets are skipped; QUEUED / GENERATING / etc. assets
  are left alone (already pending); FAILED assets are re-enqueued.
- **Budget cap is never exceeded.** At most ``budget_cap`` jobs are
  enqueued per run; the overflow is reported as ``deferred`` for a later
  run. ``budget_cap=0`` means unlimited.
- **Idempotent.** A second run with no changes enqueues nothing — the
  previously-enqueued assets are now QUEUED (pending), so they are not
  re-published.
- **Pre-warming.** Feed the reconciler the specs for the current Season
  followed by upcoming Seasons (in priority order) in a single call; the
  shared budget naturally spends on the current Season first and pre-warms
  the rest with whatever budget remains. Assets shared across Seasons are
  de-duplicated by content-address and enqueued once.

The reconciler does no generation itself and calls no provider. It only
diffs and enqueues; the background worker (T-ML-051) does the work.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from pathlib import Path

from app.services.asset_gen.models import AssetSpec, AssetStatus
from app.services.asset_gen.queue import AssetSubmissionService
from app.services.asset_gen.spend_cap import AssetGenBudgetExceededError

logger = logging.getLogger(__name__)

# Statuses that mean "work is already in flight" — the reconciler leaves
# these alone so a re-run does not double-enqueue them.
_PENDING_STATUSES = frozenset(
    {
        AssetStatus.DESIRED,
        AssetStatus.QUEUED,
        AssetStatus.GENERATING,
        AssetStatus.POSTPROCESSING,
        AssetStatus.QA,
    },
)


@dataclass(frozen=True, slots=True)
class ReconcileOutcome:
    """What a reconcile run decided. Addresses are content-addresses."""

    desired: int
    enqueued: tuple[str, ...] = ()
    already_ready: tuple[str, ...] = ()
    already_pending: tuple[str, ...] = ()
    deferred: tuple[str, ...] = ()
    budget_cap: int = 0
    season_id: str = ""
    # True when the per-environment spend cap (T-INFRA-040) halted this run
    # before all candidates were enqueued. The remaining candidates are in
    # `deferred`; the cap's alert sink has already fired.
    spend_capped: bool = False

    @property
    def budget_remaining(self) -> int:
        """Remaining headroom this run. 0 when unlimited (``budget_cap=0``)."""
        if self.budget_cap <= 0:
            return 0
        return max(0, self.budget_cap - len(self.enqueued))


class AssetReconciler:
    """Diffs desired vs ready/in-flight and enqueues the difference."""

    def __init__(self, *, submission: AssetSubmissionService) -> None:
        self._submission = submission
        self._repository = submission.repository

    def reconcile(
        self,
        specs: Iterable[AssetSpec],
        *,
        budget_cap: int = 0,
        dry_run: bool = False,
        season_id: str = "",
    ) -> ReconcileOutcome:
        """Converge the repository toward *specs*.

        Args:
            specs: Desired assets, in priority order. De-duplicated by
                content-address (first occurrence wins), so the current
                Season's specs should come before upcoming Seasons' for
                pre-warming.
            budget_cap: Max jobs to enqueue this run; 0 = unlimited.
            dry_run: Classify and report what *would* be enqueued without
                touching the repository or the queue.
            season_id: Optional label echoed into the outcome / logs.
        """
        if budget_cap < 0:
            raise ValueError("budget_cap must be >= 0")

        enqueued: list[str] = []
        already_ready: list[str] = []
        already_pending: list[str] = []
        deferred: list[str] = []

        seen: set[str] = set()
        desired_count = 0
        spend_capped = False
        for spec in specs:
            address = spec.content_address
            if address in seen:
                continue  # same asset twice (incl. shared across seasons)
            seen.add(address)
            desired_count += 1

            record = self._repository.get(address)
            if record is not None and record.status == AssetStatus.READY:
                already_ready.append(address)
                continue
            if record is not None and record.status in _PENDING_STATUSES:
                already_pending.append(address)
                continue

            # Missing or FAILED → a (re)generation candidate.
            if spend_capped or (budget_cap and len(enqueued) >= budget_cap):
                deferred.append(address)
                continue
            if dry_run:
                enqueued.append(address)
                continue
            try:
                self._submission.submit(spec)
            except AssetGenBudgetExceededError:
                # The per-environment spend cap tripped. Halt: this and
                # every remaining candidate are deferred to a later window
                # (the cap already alerted). Assets already enqueued stand.
                spend_capped = True
                deferred.append(address)
                continue
            enqueued.append(address)

        outcome = ReconcileOutcome(
            desired=desired_count,
            enqueued=tuple(enqueued),
            already_ready=tuple(already_ready),
            already_pending=tuple(already_pending),
            deferred=tuple(deferred),
            budget_cap=budget_cap,
            season_id=season_id,
            spend_capped=spend_capped,
        )
        logger.info(
            "asset_reconciler.run",
            extra={
                "season_id": season_id,
                "desired": outcome.desired,
                "enqueued": len(outcome.enqueued),
                "already_ready": len(outcome.already_ready),
                "already_pending": len(outcome.already_pending),
                "deferred": len(outcome.deferred),
                "budget_cap": budget_cap,
                "dry_run": dry_run,
            },
        )
        return outcome


# --------------------------------------------------------------------------- #
# Manifest loading
# --------------------------------------------------------------------------- #
@dataclass(frozen=True, slots=True)
class LoadedManifest:
    """A parsed asset manifest: its season id and the desired specs."""

    season_id: str
    specs: tuple[AssetSpec, ...] = field(default_factory=tuple)


def load_manifest_specs(path: Path) -> LoadedManifest:
    """Load and validate one ``*.manifest.json`` into desired specs.

    The manifest's top-level ``season_id`` is injected into each asset (the
    per-asset objects don't carry it). ``AssetSpec.from_dict`` validates
    every asset's stamped ``content_address`` against the recomputed hash,
    so a manifest whose addresses drifted from the generation inputs fails
    loud here rather than silently mis-deduplicating later.
    """
    doc = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: manifest root must be an object")
    season_id = str(doc.get("season_id", ""))
    assets_raw = doc.get("assets", [])
    if not isinstance(assets_raw, list):
        raise ValueError(f"{path}: 'assets' must be a list")
    specs: list[AssetSpec] = []
    for asset in assets_raw:
        if not isinstance(asset, dict):
            raise ValueError(f"{path}: each asset must be an object")
        merged = {**asset, "season_id": asset.get("season_id", season_id)}
        specs.append(AssetSpec.from_dict(merged))
    return LoadedManifest(season_id=season_id, specs=tuple(specs))


def load_manifest_dir(root: Path) -> tuple[AssetSpec, ...]:
    """Load every ``*.manifest.json`` under *root*, in sorted path order.

    Sorted order makes pre-warming deterministic: name season directories
    so the current Season sorts before upcoming ones, then feed the whole
    sequence to :meth:`AssetReconciler.reconcile` with a shared budget.
    """
    specs: list[AssetSpec] = []
    for path in sorted(root.rglob("*.manifest.json")):
        specs.extend(load_manifest_specs(path).specs)
    return tuple(specs)


def reconcile_specs_in_order(
    reconciler: AssetReconciler,
    spec_groups: Sequence[Sequence[AssetSpec]],
    *,
    budget_cap: int = 0,
    dry_run: bool = False,
) -> ReconcileOutcome:
    """Reconcile several priority-ordered groups under one shared budget.

    Concatenates the groups (current Season first, upcoming Seasons next)
    and runs a single reconcile so the budget is spent in priority order —
    the pre-warming entry point.
    """
    flat: list[AssetSpec] = []
    for group in spec_groups:
        flat.extend(group)
    return reconciler.reconcile(flat, budget_cap=budget_cap, dry_run=dry_run)
