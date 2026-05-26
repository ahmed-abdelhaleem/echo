"""Prompt assembly (T-ML-042).

Turns a selected :class:`ReflectionTemplate` + signal moments + the
trait vector into an LLM :class:`CompletionRequest`. The prompt has
two halves:

- A **system message** that reasserts the Echo voice rules verbatim
  from docs/04. We re-send these on every request rather than
  caching them in the provider's system prompt store because the
  template-specific ``voice_notes`` are layered on top and change
  per call.
- A **user message** that lists the signal moments and the
  template's ``voice_notes`` for this particular template, and asks
  the LLM to produce one reflection that matches those notes.

The assembler is deterministic for a given (template, signal_moments,
trait_vector) tuple: no random shuffling. This matters because the
LLM-side temperature is non-zero; we want the prompt itself to be a
fixed function of the inputs so post-hoc replay can reproduce the
same request.
"""

from __future__ import annotations

from collections.abc import Sequence

from app.services.llm.types import CompletionRequest, Message
from app.services.reflection_templates import (
    ATTACHMENT_ORDER,
    BIG_FIVE_ORDER,
    SCHWARTZ_ORDER,
    ReflectionTemplate,
)

# We send the same voice-rules system prompt on every request. It is
# the contract every reflection lives inside. Keep this in sync with
# docs/04 §"Voice rules"; if a rule changes there, change it here.
_SYSTEM_PROMPT: str = """You are Echo, a reflection writer for a personality-portrait game.

You write one reflection at a time. The reflection describes the player's day to them.

Voice rules (non-negotiable):
- Second person. Use "you". Never "the user", "this person", "she", "he", or "they".
- Specific. Every clause must ground in something the player actually did today \
(a signal moment passed to you in the prompt). A reflection that could describe \
anyone is a failed reflection.
- 3 to 5 sentences. Stop at 5.
- Echo describes; it does not evaluate. Never flattering, never roasting.
- No clinical terms. Never "neurotic", "narcissistic", "depressed", "avoidant", \
"bipolar", "anxiety disorder", or any diagnostic vocabulary.
- No archetypes. Never "the helper", "the rebel", "the curious one". \
Never "you are the X".
- Acknowledge contradiction. Real people are contradictory; reflect that where \
the data supports it.

Return only the reflection prose. No preamble, no quotes, no markdown, no headings."""


def build_prompt(
    template: ReflectionTemplate,
    *,
    signal_moments: Sequence[str] = (),
    big_five: Sequence[float] = (),
    schwartz: Sequence[float] = (),
    attachment: Sequence[float] = (),
    max_output_tokens: int = 250,
    temperature: float = 0.7,
) -> CompletionRequest:
    """Assemble the LLM request for one reflection.

    Args:
        template: The selected reflection template.
        signal_moments: 0-N concrete moments from the play through to
            anchor specificity. Empty list is allowed; the tone
            classifier will then accept any text (the specificity
            check needs moments to enforce against). In practice the
            pipeline supplies 1-3 moments.
        big_five, schwartz, attachment: The trait vector. The
            assembler renders these as a compact dimension summary
            in the user prompt so the LLM knows which signals were
            strong without seeing the raw 18 floats.
        max_output_tokens: Cap on response length.
        temperature: LLM sampling temperature.

    Returns:
        A :class:`CompletionRequest` ready to hand to an
        :class:`LLMClient`.
    """
    moments_block = _format_moments(signal_moments)
    voice_block = _format_voice_notes(template)
    exemplar_block = _format_exemplar(template)
    trait_block = _format_trait_summary(big_five, schwartz, attachment)

    user_prompt = (
        f"Template: {template.id} (v{template.version})\n"
        f"Summary: {template.summary}\n"
        f"\n"
        f"Trait highlights:\n{trait_block}\n"
        f"\n"
        f"Signal moments from this play through:\n{moments_block}\n"
        f"\n"
        f"Template-specific voice notes:\n{voice_block}\n"
        f"\n"
        f"Reference exemplar (do not copy; match the texture):\n{exemplar_block}\n"
        f"\n"
        f"Write the reflection now."
    )

    return CompletionRequest(
        messages=(
            Message(role="system", content=_SYSTEM_PROMPT),
            Message(role="user", content=user_prompt),
        ),
        max_output_tokens=max_output_tokens,
        temperature=temperature,
        stop_sequences=("\n\n\n",),
        metadata={
            "template_id": template.id,
            "template_version": str(template.version),
        },
    )


def _format_moments(moments: Sequence[str]) -> str:
    if not moments:
        return (
            "(no specific moments supplied; describe the texture of the day in "
            "general but stay specific)"
        )
    return "\n".join(f"- {moment}" for moment in moments)


def _format_voice_notes(template: ReflectionTemplate) -> str:
    lines: list[str] = []
    if template.voice_notes.emphasize:
        emphasis = ", ".join(template.voice_notes.emphasize)
        lines.append(f"Emphasize: {emphasis}")
    if template.voice_notes.avoid:
        avoid = "; ".join(f'"{phrase}"' for phrase in template.voice_notes.avoid)
        lines.append(f"Avoid these phrases: {avoid}")
    if template.voice_notes.notes:
        lines.append(f"Notes: {template.voice_notes.notes}")
    return "\n".join(lines) if lines else "(none)"


def _format_exemplar(template: ReflectionTemplate) -> str:
    """Render the first exemplar as a single string for few-shot context.

    We deliberately send only one exemplar per request (not all of
    them) so the LLM doesn't pattern-match too tightly on shape. The
    exemplar's signal_moments are stripped — what we want the LLM to
    learn is the *texture* of the prose, not the specific moments.
    """
    if not template.exemplars:
        return "(no exemplar)"
    exemplar = template.exemplars[0]
    return exemplar.output


def _format_trait_summary(
    big_five: Sequence[float],
    schwartz: Sequence[float],
    attachment: Sequence[float],
) -> str:
    """Compact "high openness; low conscientiousness; anxious-attachment prominent"
    style summary instead of dumping 18 floats."""
    parts: list[str] = []
    for dim, value in _pairs(BIG_FIVE_ORDER, big_five):
        direction = _bipolar_direction(value)
        if direction is not None:
            parts.append(f"{dim} {direction}")
    for dim, value in _pairs(SCHWARTZ_ORDER, schwartz):
        direction = _bipolar_direction(value)
        if direction is not None:
            parts.append(f"{dim} {direction}")
    for dim, value in _pairs(ATTACHMENT_ORDER, attachment):
        direction = _unipolar_direction(value)
        if direction is not None:
            parts.append(f"{dim} {direction}")
    return "; ".join(parts) if parts else "(quiet across all dimensions)"


def _pairs(order: Sequence[str], values: Sequence[float]) -> list[tuple[str, float]]:
    return list(zip(order, values, strict=False))


def _bipolar_direction(value: float) -> str | None:
    if value >= 0.4:
        return "high"
    if value <= -0.4:
        return "low"
    return None


def _unipolar_direction(value: float) -> str | None:
    if value >= 0.4:
        return "prominent"
    return None
