"""Tests for the tone classifier (T-ML-042)."""

from __future__ import annotations

import pytest

from app.services.reflection.tone import ToneClassifier, default_tone_classifier
from app.services.reflection_templates import default_template_dir, load_templates


@pytest.fixture(scope="module")
def templates() -> tuple:
    return load_templates(default_template_dir())


@pytest.fixture
def classifier() -> ToneClassifier:
    return default_tone_classifier()


def _find_template(templates: tuple, template_id: str):
    for t in templates:
        if t.id == template_id:
            return t
    raise AssertionError(f"template {template_id!r} not in library")


def test_canonical_reflection_passes(classifier: ToneClassifier) -> None:
    text = (
        "You wrote down a word you did not yet know. "
        "You took a side street that was not on the way home. "
        "Neither was useful, and both were the same gesture."
    )
    result = classifier.classify(text, signal_moments=["the unfamiliar word"])
    assert result.passed, result
    assert result.sentence_count == 3
    assert result.word_count > 0


def test_missing_second_person_fails(classifier: ToneClassifier) -> None:
    text = (
        "The day pulled toward what was new. "
        "Three small detours stacked up by sundown. "
        "Tomorrow there will be more."
    )
    result = classifier.classify(text, signal_moments=["a detour"])
    assert not result.passed
    assert result.reason == "not-second-person"


def test_too_few_sentences_fails(classifier: ToneClassifier) -> None:
    text = "You went home early."
    result = classifier.classify(text, signal_moments=["home"])
    assert not result.passed
    assert result.reason == "sentence-count"


def test_too_many_sentences_fails(classifier: ToneClassifier) -> None:
    text = ". ".join(["You did one small thing"] * 7) + "."
    result = classifier.classify(text, signal_moments=["one small thing"])
    assert not result.passed
    assert result.reason == "sentence-count"


def test_word_cap_fails(classifier: ToneClassifier) -> None:
    sentence = "You walked through the long corridor again "
    text = " ".join([f"{sentence}{i}." for i in range(20)])  # ~260 words
    result = classifier.classify(text, signal_moments=["corridor"])
    assert not result.passed
    assert result.reason in {"word-cap", "sentence-count"}


@pytest.mark.parametrize(
    "phrase",
    [
        "the helper",
        "the rebel",
        "the curious one",
        "the explorer",
        "you are the rebel",
        "you're the curious one",
    ],
)
def test_archetype_phrases_fail(classifier: ToneClassifier, phrase: str) -> None:
    text = (
        f"You moved through the day; {phrase} took the long way around. "
        "You wrote one thing down. "
        "Tonight you will sleep on it."
    )
    result = classifier.classify(text, signal_moments=["the day"])
    assert not result.passed
    assert result.reason == "archetype"


def test_third_person_about_other_people_passes(
    classifier: ToneClassifier,
) -> None:
    """Third-person pronouns referring to *other* people the player
    encountered are fine. The binding rule from docs/04 is that the
    *player* is referenced in second person; that's covered by the
    second-person-presence check, not by blanket-banning ``she``/``he``."""
    text = (
        "You watched the person at the door fail to find their keys. "
        "You did not offer to help, and that was the choice you made. "
        "Tonight you will think about it once and then sleep."
    )
    result = classifier.classify(text, signal_moments=["the person at the door"])
    assert result.passed, result


def test_specificity_check_passes_with_moment_word(
    classifier: ToneClassifier,
) -> None:
    text = (
        "You reread the list in cleaner handwriting. "
        "You went back once for the small thing you almost forgot. "
        "That was a kindness."
    )
    result = classifier.classify(
        text,
        signal_moments=["the list you cleaned", "the small thing you almost forgot"],
    )
    assert result.passed, result


def test_specificity_check_fails_without_moment_words(
    classifier: ToneClassifier,
) -> None:
    text = (
        "You moved through it carrying nothing in particular. "
        "Some small intent shaped each of your turns. "
        "Tomorrow will be a different shape."
    )
    result = classifier.classify(
        text, signal_moments=["the conversation with your sibling about taxes"]
    )
    assert not result.passed
    assert result.reason == "not-specific"


def test_specificity_check_permissive_when_no_moments(
    classifier: ToneClassifier,
) -> None:
    """With no signal moments supplied, the specificity rule is skipped."""
    text = (
        "You moved through the day carrying things you did not name. "
        "Some were heavier than they looked. "
        "Tomorrow will be a different shape."
    )
    result = classifier.classify(text, signal_moments=())
    assert result.passed


def test_template_forbidden_terms_fail(classifier: ToneClassifier, templates: tuple) -> None:
    """A reflection that mentions 'neurotic' against the high-neuroticism
    template should trip the template-specific forbidden-term check
    even though it would also fail the safety classifier upstream."""
    template = _find_template(templates, "high-neuroticism")
    text = (
        "You felt neurotic about the slightly-open window. "
        "You closed it twice. "
        "Then you went outside on purpose."
    )
    result = classifier.classify(text, template=template, signal_moments=["the window"])
    assert not result.passed
    # Either archetype-style avoid term OR forbidden-term, both are correct fails.
    assert result.reason in {"forbidden-term", "archetype"}


def test_template_voice_notes_avoid_phrases_fail(
    classifier: ToneClassifier, templates: tuple
) -> None:
    template = _find_template(templates, "high-extraversion")
    # The high-extraversion template's avoid list includes phrases like
    # "you are an extrovert".
    text = (
        "You moved toward the room with the louder conversation. "
        "You are an extrovert about it. "
        "Tonight you will be tired."
    )
    result = classifier.classify(
        text, template=template, signal_moments=["the louder conversation"]
    )
    assert not result.passed
    assert result.reason == "archetype"


def test_template_sentence_count_constraints_are_honoured(
    classifier: ToneClassifier, templates: tuple
) -> None:
    template = _find_template(templates, "high-openness")
    # Six sentences should exceed the template's max (5).
    text = " ".join(
        [
            "You did one thing on purpose.",
            "You did a second thing without thinking.",
            "You wrote both down.",
            "Then you went home.",
            "You read what you wrote on the way.",
            "Tomorrow will be different.",
        ]
    )
    result = classifier.classify(text, template=template, signal_moments=["one thing"])
    assert not result.passed
    assert result.reason == "sentence-count"
