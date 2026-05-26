"""Safety classifier (T-ML-042).

A *fail-closed* heuristic check that runs after the LLM produces text
and before we hand the reflection back to the user. The classifier
flags any of:

1. Clinical diagnostic vocabulary (``neurotic``, ``narcissistic``,
   ``depression`` and similar). Echo deliberately does not pathologise;
   docs/04 §"Voice rules" forbids these.
2. Self-harm and crisis-adjacent phrases. The product does not have a
   crisis-mode pathway yet; the safest response if the LLM emits this
   text is to fall back to a neutral curated string and surface a
   structured event for ops review (PR D' will wire that telemetry).
3. Diagnostic second-person constructions ("you have anxiety",
   "you suffer from depression"). These are clinical even when the
   word itself wouldn't fire on the vocabulary check.
4. Roasting / shaming patterns ("you are worthless", "you should be
   ashamed"). Echo describes; it does not evaluate.

The classifier is intentionally rule-based and stdlib-only. Larger
sentence-transformers / Hugging Face classifiers are queued for a
later pass per docs/06 §"ML / content generation" but are not
required by T-ML-042's acceptance criterion. A rule-based classifier
gives us a deterministic, auditable baseline; the embedding-based
classifier will be a *layered* addition rather than a replacement.

Public API:

    >>> sc = default_safety_classifier()
    >>> sc.classify("you reread the list before going home.")
    SafetyResult(passed=True, reason=None, matched_term=None)
    >>> sc.classify("you are clearly narcissistic.")
    SafetyResult(passed=False, reason='clinical-term', matched_term='narcissistic')
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Final

# Clinical / diagnostic vocabulary the player should never see in a
# reflection. Matched as whole words, case-insensitive. Includes the
# common adjective + noun forms.
_CLINICAL_TERMS: Final[tuple[str, ...]] = (
    "neurotic",
    "neuroticism",
    "narcissist",
    "narcissistic",
    "narcissism",
    "depressed",
    "depression",
    "depressive",
    "anxious disorder",
    "anxiety disorder",
    "panic disorder",
    "personality disorder",
    "bipolar",
    "manic",
    "psychotic",
    "psychosis",
    "psychopath",
    "psychopathic",
    "sociopath",
    "sociopathic",
    "schizoid",
    "schizophrenic",
    "schizophrenia",
    "ptsd",
    "adhd",
    "ocd",
    "autistic",
    "asperger",
    "histrionic",
    "borderline personality",
    "avoidant personality",
    "dependent personality",
    "obsessive-compulsive",
    "manic-depressive",
    "mental illness",
    "mental disorder",
    "diagnosable",
    "pathological",
    "delusional",
)


# Crisis-adjacent / self-harm phrases. These are matched as substrings
# (case-insensitive) because the pattern matters even when the
# surrounding words are unusual.
_CRISIS_PATTERNS: Final[tuple[str, ...]] = (
    "kill yourself",
    "kill themselves",
    "end it all",
    "end your life",
    "take your own life",
    "self-harm",
    "self harm",
    "suicide",
    "suicidal",
    "should die",
    "deserve to die",
    "no point in living",
    "not worth living",
    "harm yourself",
    "hurt yourself",
    "cut yourself",
)


# Diagnostic phrasings that don't trigger the vocabulary check on
# their own. Matched as case-insensitive substrings; we keep this set
# tight to minimise false positives on reflection prose.
_DIAGNOSTIC_PHRASES: Final[tuple[str, ...]] = (
    "you suffer from",
    "you are diagnosed",
    "you are clinically",
    "you exhibit symptoms",
    "symptoms of ",
    "diagnosis of ",
)


# Roasting / shaming patterns. These trip even on lower-grade negative
# evaluative language; Echo describes, it does not evaluate.
_ROAST_PATTERNS: Final[tuple[str, ...]] = (
    "you are worthless",
    "you're worthless",
    "you are pathetic",
    "you're pathetic",
    "you are broken",
    "you should be ashamed",
    "you should feel ashamed",
    "you should hate yourself",
    "shame on you",
    "you are a failure",
    "you're a failure",
    "you are a disappointment",
    "you're a disappointment",
)


@dataclass(frozen=True, slots=True)
class SafetyResult:
    """Outcome of the safety classifier.

    Fields:
        passed: True if no rule fired. False is fail-closed: the
            pipeline returns the curated fallback string and records
            the reason.
        reason: Short rule identifier when ``passed=False``. One of
            ``clinical-term``, ``crisis``, ``diagnostic-phrase``,
            ``roast``, or ``None`` when ``passed=True``. Used for
            telemetry; the player never sees it.
        matched_term: The specific term that triggered the rule.
            Logged by ops; not user-facing.
    """

    passed: bool
    reason: str | None = None
    matched_term: str | None = None


class SafetyClassifier:
    """Rule-based safety classifier.

    Instances are stateless and safe to share across requests. The
    constructor lets you override any rule list so the test suite can
    exercise edge cases independently.
    """

    def __init__(
        self,
        *,
        clinical_terms: tuple[str, ...] = _CLINICAL_TERMS,
        crisis_patterns: tuple[str, ...] = _CRISIS_PATTERNS,
        diagnostic_phrases: tuple[str, ...] = _DIAGNOSTIC_PHRASES,
        roast_patterns: tuple[str, ...] = _ROAST_PATTERNS,
    ) -> None:
        self._clinical_re = _compile_word_boundary_alternation(clinical_terms)
        self._crisis = tuple(p.lower() for p in crisis_patterns)
        self._diagnostic = tuple(p.lower() for p in diagnostic_phrases)
        self._roast = tuple(p.lower() for p in roast_patterns)

    def classify(self, text: str) -> SafetyResult:
        lowered = text.lower()

        for pattern in self._crisis:
            if pattern in lowered:
                return SafetyResult(
                    passed=False,
                    reason="crisis",
                    matched_term=pattern,
                )

        match = self._clinical_re.search(text)
        if match is not None:
            return SafetyResult(
                passed=False,
                reason="clinical-term",
                matched_term=match.group(0),
            )

        for pattern in self._diagnostic:
            if pattern in lowered:
                return SafetyResult(
                    passed=False,
                    reason="diagnostic-phrase",
                    matched_term=pattern,
                )

        for pattern in self._roast:
            if pattern in lowered:
                return SafetyResult(
                    passed=False,
                    reason="roast",
                    matched_term=pattern,
                )

        return SafetyResult(passed=True)


def default_safety_classifier() -> SafetyClassifier:
    """The classifier the production pipeline uses.

    Wrapped in a function (not a module-level singleton) so tests can
    instantiate it fresh without spooky-shared state.
    """
    return SafetyClassifier()


def _compile_word_boundary_alternation(terms: tuple[str, ...]) -> re.Pattern[str]:
    """Compile a case-insensitive whole-word alternation for ``terms``.

    Multi-word terms are matched with whole-phrase boundaries
    (preceding and trailing word boundary), not per-word boundaries,
    so "borderline personality" matches but "border" alone does not.
    """
    parts = [re.escape(term) for term in terms]
    pattern = r"\b(?:" + "|".join(parts) + r")\b"
    return re.compile(pattern, re.IGNORECASE)
