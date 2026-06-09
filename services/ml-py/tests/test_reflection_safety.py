"""Tests for the safety classifier (T-ML-042)."""

from __future__ import annotations

import pytest

from app.services.reflection.safety import SafetyClassifier, default_safety_classifier


@pytest.fixture
def classifier() -> SafetyClassifier:
    return default_safety_classifier()


def test_safe_reflection_passes(classifier: SafetyClassifier) -> None:
    text = (
        "You reread the list in cleaner handwriting. "
        "You went back once for the small thing you almost forgot. "
        "That was a kindness to the version of you that wakes up tomorrow."
    )
    result = classifier.classify(text)
    assert result.passed
    assert result.reason is None
    assert result.matched_term is None


@pytest.mark.parametrize(
    "term",
    [
        "neurotic",
        "narcissistic",
        "depressed",
        "depression",
        "bipolar",
        "PTSD",
        "ADHD",
        "OCD",
        "anxiety disorder",
        "borderline personality",
        "schizoid",
        "mental illness",
    ],
)
def test_clinical_terms_fail_closed(classifier: SafetyClassifier, term: str) -> None:
    text = f"You sometimes act {term} when the day gets too long."
    result = classifier.classify(text)
    assert not result.passed
    assert result.reason == "clinical-term"
    assert result.matched_term is not None
    assert result.matched_term.lower() == term.lower()


def test_clinical_term_partial_match_does_not_fire(
    classifier: SafetyClassifier,
) -> None:
    """``manic`` would fire; ``mechanical`` (which contains the substring ``manic``) must not."""
    text = "You felt a mechanical calm in the morning."
    result = classifier.classify(text)
    assert result.passed


@pytest.mark.parametrize(
    "phrase",
    [
        "you should kill yourself",
        "you wanted to end it all",
        "thoughts of suicide",
        "you should die",
        "no point in living",
        "you should harm yourself",
    ],
)
def test_crisis_phrases_fail_closed(classifier: SafetyClassifier, phrase: str) -> None:
    text = f"Today {phrase} stayed nowhere near you."
    result = classifier.classify(text)
    assert not result.passed
    assert result.reason == "crisis"


@pytest.mark.parametrize(
    "phrase",
    [
        "you suffer from anxiety",
        "you are diagnosed with something",
        "you exhibit symptoms of perfectionism",
        "diagnosis of inattention",
    ],
)
def test_diagnostic_phrases_fail_closed(classifier: SafetyClassifier, phrase: str) -> None:
    text = f"Today {phrase}."
    result = classifier.classify(text)
    assert not result.passed
    assert result.reason in {"diagnostic-phrase", "clinical-term"}


@pytest.mark.parametrize(
    "phrase",
    [
        "you are worthless",
        "you're worthless",
        "you are pathetic",
        "you are a failure",
        "you are a disappointment",
        "you should be ashamed",
    ],
)
def test_roast_phrases_fail_closed(classifier: SafetyClassifier, phrase: str) -> None:
    text = f"In the end, {phrase} today."
    result = classifier.classify(text)
    assert not result.passed
    assert result.reason == "roast"


def test_classifier_returns_first_match(classifier: SafetyClassifier) -> None:
    """When multiple rules could fire, crisis takes precedence (highest severity)."""
    text = "You felt narcissistic and thought about suicide briefly."
    result = classifier.classify(text)
    assert not result.passed
    assert result.reason == "crisis"


def test_empty_string_passes(classifier: SafetyClassifier) -> None:
    """Empty text contains nothing problematic. (The pipeline checks
    emptiness separately via the tone classifier's sentence count.)"""
    result = classifier.classify("")
    assert result.passed


def test_case_insensitive_clinical_match(classifier: SafetyClassifier) -> None:
    text = "You acted Narcissistic for a moment."
    result = classifier.classify(text)
    assert not result.passed
    assert result.reason == "clinical-term"


def test_custom_classifier_with_overrides() -> None:
    """The constructor accepts overrides so tests can exercise edge cases."""
    sc = SafetyClassifier(
        clinical_terms=("foo",),
        crisis_patterns=(),
        diagnostic_phrases=(),
        roast_patterns=(),
    )
    assert not sc.classify("you are foo today").passed
    assert sc.classify("you are neurotic today").passed
