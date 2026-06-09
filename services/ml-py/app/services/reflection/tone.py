"""Tone classifier (T-ML-042).

Sits downstream of the safety classifier. The safety classifier
catches *what we will never publish under any circumstance*; the tone
classifier catches *what we won't publish under this template's voice
rules*. Both fail-closed to the curated fallback.

Rules checked (all derived from docs/04 §"The prose reflection" and
the per-template ``voice_notes`` / ``constraints``):

1. **Second person.** The reflection must contain at least one
   instance of ``you`` / ``your`` / ``yours`` / ``yourself`` as a
   word. Without that we are not writing reflection prose.
2. **Sentence count.** Between ``min_sentences`` and ``max_sentences``
   (default 3-5; templates may narrow). Sentences are delimited by
   ``.``, ``?``, ``!``.
3. **Word count cap.** ≤ 200 words. Reflections that drift longer
   stop reading like Echo.
4. **No archetype phrasings.** ``the helper``, ``the rebel``,
   ``the curious one``, ``you are the X``. Template-specific
   variants are also rejected via ``voice_notes.avoid``.
5. **Specificity.** The reflection must reference at least one of the
   signal moments. A reflection that could describe anyone is a
   failed reflection (docs/04). Specificity is checked by stemming
   each signal moment into its meaningful nouns and verifying at
   least one appears in the output. Defaults to permissive when no
   signal moments were supplied (so tests of the classifier in
   isolation don't trip the rule).
6. **Template forbidden terms.** ``constraints.forbidden_terms`` plus
   ``voice_notes.avoid``. Whole-word, case-insensitive.

(We deliberately do NOT fire on ``she`` / ``he`` / ``they`` /
``them`` etc. in general. A reflection often references *other*
people or objects in third person — "both of them were the same
gesture", "the person at the door" — and that is fine. The binding
rule from docs/04 is that the *player* is referenced in second
person, which is covered by the second-person-presence check above.)

The classifier is rule-based and stdlib-only — same rationale as
:mod:`safety`. The embedding-based companion classifier is a
later pass.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Final

from app.services.reflection_templates import ReflectionTemplate

_DEFAULT_ARCHETYPES: Final[tuple[str, ...]] = (
    "the helper",
    "the rebel",
    "the explorer",
    "the curious one",
    "the careful one",
    "the open one",
    "the warm one",
    "the cold one",
    "the closed one",
    "the disciplined one",
    "the wild one",
    "the leader",
    "the follower",
    "the analyst",
    "the empath",
    "the perfectionist",
    "you are the ",
    "you're the ",
)

_DEFAULT_WORD_CAP: Final[int] = 200
_DEFAULT_MIN_SENTENCES: Final[int] = 3
_DEFAULT_MAX_SENTENCES: Final[int] = 5

_SENTENCE_TERMINATOR_RE: Final[re.Pattern[str]] = re.compile(r"[.!?]")
_SECOND_PERSON_RE: Final[re.Pattern[str]] = re.compile(
    r"\b(?:you|your|yours|yourself)\b",
    re.IGNORECASE,
)
_WORD_RE: Final[re.Pattern[str]] = re.compile(r"\w+")


@dataclass(frozen=True, slots=True)
class ToneResult:
    """Outcome of the tone classifier.

    Fields:
        passed: True if no rule fired.
        reason: Short rule identifier when ``passed=False``. One of
            ``not-second-person``, ``sentence-count``, ``word-cap``,
            ``archetype``, ``not-specific``,
            ``forbidden-term``, or ``None`` when ``passed=True``.
        matched_term: The triggering phrase, when applicable.
        sentence_count: Number of sentences detected. Always set so
            telemetry can use it even on passing classifications.
        word_count: Number of words detected.
    """

    passed: bool
    reason: str | None = None
    matched_term: str | None = None
    sentence_count: int = 0
    word_count: int = 0


class ToneClassifier:
    """Rule-based tone classifier."""

    def __init__(
        self,
        *,
        archetypes: tuple[str, ...] = _DEFAULT_ARCHETYPES,
        word_cap: int = _DEFAULT_WORD_CAP,
    ) -> None:
        self._archetypes = tuple(p.lower() for p in archetypes)
        self._word_cap = word_cap

    def classify(
        self,
        text: str,
        *,
        template: ReflectionTemplate | None = None,
        signal_moments: Sequence[str] = (),
    ) -> ToneResult:
        sentence_count = _count_sentences(text)
        word_count = _count_words(text)

        # Second-person presence.
        if not _SECOND_PERSON_RE.search(text):
            return ToneResult(
                passed=False,
                reason="not-second-person",
                sentence_count=sentence_count,
                word_count=word_count,
            )

        # Sentence count: pull bounds from template if provided.
        if template is not None:
            min_sentences = template.constraints.min_sentences
            max_sentences = template.constraints.max_sentences
        else:
            min_sentences = _DEFAULT_MIN_SENTENCES
            max_sentences = _DEFAULT_MAX_SENTENCES

        if not min_sentences <= sentence_count <= max_sentences:
            return ToneResult(
                passed=False,
                reason="sentence-count",
                matched_term=f"{sentence_count} sentences",
                sentence_count=sentence_count,
                word_count=word_count,
            )

        # Word count cap.
        if word_count > self._word_cap:
            return ToneResult(
                passed=False,
                reason="word-cap",
                matched_term=f"{word_count} words",
                sentence_count=sentence_count,
                word_count=word_count,
            )

        # Archetype check (default list + template-specific avoid).
        archetype_terms: list[str] = list(self._archetypes)
        forbidden_terms: list[str] = []
        if template is not None:
            archetype_terms.extend(term.lower() for term in template.voice_notes.avoid)
            forbidden_terms = [term.lower() for term in template.constraints.forbidden_terms]

        lowered = text.lower()
        for phrase in archetype_terms:
            if phrase and phrase in lowered:
                return ToneResult(
                    passed=False,
                    reason="archetype",
                    matched_term=phrase,
                    sentence_count=sentence_count,
                    word_count=word_count,
                )

        # Template constraints.forbidden_terms (whole-word match where
        # the term is a single word; substring otherwise).
        for term in forbidden_terms:
            if not term:
                continue
            if " " in term or "-" in term:
                if term in lowered:
                    return ToneResult(
                        passed=False,
                        reason="forbidden-term",
                        matched_term=term,
                        sentence_count=sentence_count,
                        word_count=word_count,
                    )
            else:
                if re.search(rf"\b{re.escape(term)}\b", lowered):
                    return ToneResult(
                        passed=False,
                        reason="forbidden-term",
                        matched_term=term,
                        sentence_count=sentence_count,
                        word_count=word_count,
                    )

        # Specificity: at least one signal-moment noun must appear.
        if signal_moments and not _references_any_signal_moment(text, signal_moments):
            return ToneResult(
                passed=False,
                reason="not-specific",
                matched_term=None,
                sentence_count=sentence_count,
                word_count=word_count,
            )

        return ToneResult(
            passed=True,
            sentence_count=sentence_count,
            word_count=word_count,
        )


def default_tone_classifier() -> ToneClassifier:
    """The classifier the production pipeline uses."""
    return ToneClassifier()


def _count_sentences(text: str) -> int:
    """Count sentence-terminated segments.

    "Today you wrote it down. Then you went home." -> 2

    Trailing fragments without a terminator are counted as one
    additional sentence; a string with no terminators returns 1 if
    non-empty.
    """
    stripped = text.strip()
    if not stripped:
        return 0
    # Strip trailing terminators so we don't over-count.
    trimmed = stripped.rstrip(".!?")
    parts = _SENTENCE_TERMINATOR_RE.split(trimmed)
    parts = [p for p in parts if p.strip()]
    return max(1, len(parts))


def _count_words(text: str) -> int:
    return len(_WORD_RE.findall(text))


def _references_any_signal_moment(text: str, moments: Sequence[str]) -> bool:
    """True if any "meaningful" word from any signal moment appears in ``text``.

    "Meaningful" here means a word that is at least 4 characters and is
    not in a small English stopword set. The intent is to catch
    "you wrote down the unfamiliar word" matching the moment
    "the unfamiliar word you wrote down" without requiring exact
    substring overlap.
    """
    text_words = {w.lower() for w in _WORD_RE.findall(text)}
    if not text_words:
        return False
    for moment in moments:
        for word in _WORD_RE.findall(moment.lower()):
            if len(word) >= 4 and word not in _STOPWORDS and word in text_words:
                return True
    return False


# A tiny stopword list. We do not want "the", "and", "with" etc. to
# count toward specificity since they appear in nearly every English
# sentence.
_STOPWORDS: Final[frozenset[str]] = frozenset(
    {
        "about",
        "after",
        "again",
        "also",
        "another",
        "back",
        "because",
        "been",
        "being",
        "between",
        "both",
        "could",
        "does",
        "doing",
        "down",
        "each",
        "even",
        "every",
        "from",
        "have",
        "having",
        "here",
        "into",
        "just",
        "like",
        "more",
        "most",
        "much",
        "must",
        "never",
        "other",
        "over",
        "same",
        "should",
        "some",
        "such",
        "than",
        "that",
        "their",
        "them",
        "then",
        "there",
        "these",
        "they",
        "this",
        "those",
        "through",
        "under",
        "until",
        "very",
        "were",
        "what",
        "when",
        "where",
        "which",
        "while",
        "with",
        "would",
        "your",
        "yours",
        "yourself",
    },
)
