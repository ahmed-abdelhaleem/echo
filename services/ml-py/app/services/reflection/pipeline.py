"""Reflection pipeline (T-ML-042).

Glues template selection + prompt assembly + LLM completion + safety
classification + tone classification into one entry point. Returns a
:class:`ReflectionResult` regardless of what failed; nothing inside
this pipeline raises on a real, expected failure path. Programmer
errors (missing templates, bad config) still raise on construction.
"""

from __future__ import annotations

import asyncio
import logging
import os
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field

from app.services.llm import (
    AllProvidersFailedError,
    LLMClient,
    LLMError,
    RoutingLLMClient,
    build_client_from_env,
)
from app.services.reflection.prompt import build_prompt
from app.services.reflection.safety import (
    SafetyClassifier,
    SafetyResult,
    default_safety_classifier,
)
from app.services.reflection.tone import (
    ToneClassifier,
    ToneResult,
    default_tone_classifier,
)
from app.services.reflection_templates import (
    ReflectionTemplate,
    default_template_dir,
    load_templates,
    select_candidates,
)

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class ClassifierScores:
    """Result of running both classifiers."""

    safety: SafetyResult
    tone: ToneResult


@dataclass(frozen=True, slots=True)
class ReflectionResult:
    """Final output of :meth:`ReflectionPipeline.generate`.

    Fields:
        text: The reflection prose. Always non-empty.
        template_id: The id of the template that was selected. If
            ``is_fallback`` is True and no template matched, this is
            ``"fallback"``.
        provider: The LLM provider that served the call. ``"none"`` if
            the pipeline fell back before the LLM was reached.
        is_fallback: True when the pipeline returned the curated
            fallback string instead of the LLM's output. Callers can
            use this to (a) log the rate at which production hits the
            fallback path and (b) decide whether to retry on a
            different seed.
        fallback_reason: Short identifier of why we fell back: one of
            ``"no-candidates"``, ``"llm-failed"``, ``"safety-failed"``,
            ``"tone-failed"``. Never user-visible.
        classifier_scores: Per-classifier outcomes. Both present even
            on the fallback path so telemetry sees what was actually
            measured.
    """

    text: str
    template_id: str
    provider: str
    is_fallback: bool
    fallback_reason: str | None
    classifier_scores: ClassifierScores | None = None
    routing_attempted_providers: tuple[str, ...] = field(default_factory=tuple)


# Curated fallback strings. The pipeline returns one of these when the
# LLM either fails or its output trips a classifier. They are
# deliberately generic (no specific signal moments) so they are safe
# to ship without LLM oversight; they obey every voice rule on their
# own.
_FALLBACK_TEXTS: tuple[str, ...] = (
    (
        "You moved through today carrying things you did not name. "
        "Some of them were heavier than they looked, and some lighter. "
        "You will see them more clearly when you have a little more distance."
    ),
    (
        "Today did not announce itself. "
        "You did a few small things on purpose and a few without thinking, and the "
        "shape of it will be easier to read tomorrow. "
        "For now it is enough that you arrived at the end of it."
    ),
    (
        "You met the day in pieces. "
        "Some pieces fit together and some did not, and you did not force them to. "
        "What stays with you tonight is the texture of having tried."
    ),
)


def _pick_fallback_text(seed: int) -> str:
    """Deterministically pick a fallback text. Same seed -> same text.

    Seeding by ``playthrough_id_hash`` lets us avoid showing the same
    player the identical fallback on consecutive sessions if both
    fall back; callers without a seed pass ``0`` for the first
    fallback string.
    """
    return _FALLBACK_TEXTS[seed % len(_FALLBACK_TEXTS)]


class ReflectionPipeline:
    """The reflection pipeline.

    Construction is cheap; the heavy work (template loading) happens
    once at startup. The same instance is shared across requests.
    """

    def __init__(
        self,
        *,
        llm_client: LLMClient,
        templates: Iterable[ReflectionTemplate],
        safety_classifier: SafetyClassifier | None = None,
        tone_classifier: ToneClassifier | None = None,
        candidate_limit: int = 3,
    ) -> None:
        self._llm_client = llm_client
        self._templates: tuple[ReflectionTemplate, ...] = tuple(templates)
        if not self._templates:
            raise ValueError("templates cannot be empty")
        self._safety = safety_classifier or default_safety_classifier()
        self._tone = tone_classifier or default_tone_classifier()
        self._candidate_limit = candidate_limit

    @property
    def templates(self) -> tuple[ReflectionTemplate, ...]:
        return self._templates

    async def generate(
        self,
        *,
        big_five: Sequence[float],
        schwartz: Sequence[float],
        attachment: Sequence[float],
        signal_moments: Sequence[str] = (),
        fallback_seed: int = 0,
    ) -> ReflectionResult:
        """End-to-end pipeline call.

        Args:
            big_five, schwartz, attachment: The trait vector.
            signal_moments: Concrete moments to anchor specificity.
            fallback_seed: Optional integer used to pick which curated
                fallback text we return if we end up on the fallback
                path. Pass the playthrough id hash so a player doesn't
                see the same fallback twice in a row.

        Returns:
            A :class:`ReflectionResult`. Never raises on a real
            expected failure path; programmer errors (bad config) may
            still raise.
        """
        candidates = select_candidates(
            big_five=big_five,
            schwartz=schwartz,
            attachment=attachment,
            templates=self._templates,
            limit=self._candidate_limit,
        )
        if not candidates:
            logger.warning("reflection.no_candidates")
            return _fallback(
                template_id="fallback",
                provider="none",
                reason="no-candidates",
                fallback_seed=fallback_seed,
            )

        top = candidates[0]
        request = build_prompt(
            top.template,
            signal_moments=signal_moments,
            big_five=big_five,
            schwartz=schwartz,
            attachment=attachment,
        )

        attempted_providers: tuple[str, ...] = ()
        try:
            if isinstance(self._llm_client, RoutingLLMClient):
                routing_result = await self._llm_client.complete_with_route(
                    request,
                )
                completion = routing_result.completion
                attempted_providers = routing_result.attempted_providers
            else:
                completion = await self._llm_client.complete(request)
                attempted_providers = (self._llm_client.provider_id,)
        except AllProvidersFailedError as exc:
            logger.warning(
                "reflection.llm_failed",
                extra={"failure_count": len(exc.failures)},
            )
            return _fallback(
                template_id=top.template.id,
                provider="none",
                reason="llm-failed",
                fallback_seed=fallback_seed,
                attempted_providers=tuple(f.provider for f in exc.failures),
            )
        except LLMError:
            logger.warning("reflection.llm_failed", exc_info=True)
            return _fallback(
                template_id=top.template.id,
                provider="none",
                reason="llm-failed",
                fallback_seed=fallback_seed,
            )

        text = completion.text.strip()

        safety = self._safety.classify(text)
        if not safety.passed:
            logger.warning(
                "reflection.safety_failed",
                extra={
                    "reason": safety.reason,
                    "matched_term": safety.matched_term,
                    "template_id": top.template.id,
                },
            )
            return _fallback(
                template_id=top.template.id,
                provider=completion.provider,
                reason="safety-failed",
                fallback_seed=fallback_seed,
                attempted_providers=attempted_providers,
                classifier_scores=ClassifierScores(
                    safety=safety,
                    tone=ToneResult(passed=False, reason="skipped-after-safety"),
                ),
            )

        tone = self._tone.classify(
            text,
            template=top.template,
            signal_moments=signal_moments,
        )
        if not tone.passed:
            logger.warning(
                "reflection.tone_failed",
                extra={
                    "reason": tone.reason,
                    "matched_term": tone.matched_term,
                    "template_id": top.template.id,
                },
            )
            return _fallback(
                template_id=top.template.id,
                provider=completion.provider,
                reason="tone-failed",
                fallback_seed=fallback_seed,
                attempted_providers=attempted_providers,
                classifier_scores=ClassifierScores(safety=safety, tone=tone),
            )

        return ReflectionResult(
            text=text,
            template_id=top.template.id,
            provider=completion.provider,
            is_fallback=False,
            fallback_reason=None,
            classifier_scores=ClassifierScores(safety=safety, tone=tone),
            routing_attempted_providers=attempted_providers,
        )

    def generate_sync(
        self,
        *,
        big_five: Sequence[float],
        schwartz: Sequence[float],
        attachment: Sequence[float],
        signal_moments: Sequence[str] = (),
        fallback_seed: int = 0,
    ) -> ReflectionResult:
        """Synchronous wrapper for sync gRPC handlers.

        Internally manages an event loop so the existing
        ``concurrent.futures`` gRPC server can call into the async
        pipeline without becoming async itself.
        """
        return asyncio.run(
            self.generate(
                big_five=big_five,
                schwartz=schwartz,
                attachment=attachment,
                signal_moments=signal_moments,
                fallback_seed=fallback_seed,
            ),
        )


def _fallback(
    *,
    template_id: str,
    provider: str,
    reason: str,
    fallback_seed: int,
    attempted_providers: tuple[str, ...] = (),
    classifier_scores: ClassifierScores | None = None,
) -> ReflectionResult:
    return ReflectionResult(
        text=_pick_fallback_text(fallback_seed),
        template_id=template_id,
        provider=provider,
        is_fallback=True,
        fallback_reason=reason,
        classifier_scores=classifier_scores,
        routing_attempted_providers=attempted_providers,
    )


def build_pipeline_from_env(
    env: dict[str, str] | None = None,
) -> ReflectionPipeline:
    """Build a fully-wired pipeline from the process environment.

    Pulls the LLM client from :func:`build_client_from_env` and the
    templates from :func:`default_template_dir`. Used by the gRPC
    bootstrap when the operator opts in via
    ``ECHO_REFLECTION_PIPELINE=enabled``.
    """
    if env is None:
        env = dict(os.environ)
    llm = build_client_from_env(env)
    templates = load_templates(default_template_dir())
    return ReflectionPipeline(llm_client=llm, templates=templates)
