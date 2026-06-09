"""Tests for the LLM prompt assembler (T-ML-042)."""

from __future__ import annotations

import pytest

from app.services.reflection.prompt import build_prompt
from app.services.reflection_templates import default_template_dir, load_templates


@pytest.fixture(scope="module")
def templates() -> tuple:
    return load_templates(default_template_dir())


def _find_template(templates: tuple, template_id: str):
    for t in templates:
        if t.id == template_id:
            return t
    raise AssertionError(f"template {template_id!r} not in library")


def test_prompt_has_system_and_user_messages(templates: tuple) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(
        template,
        signal_moments=["the unfamiliar word you wrote down"],
        big_five=(0.8, 0.0, 0.0, 0.0, 0.0),
    )
    assert len(req.messages) == 2
    assert req.messages[0].role == "system"
    assert req.messages[1].role == "user"


def test_prompt_system_message_contains_voice_rules(templates: tuple) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(template, signal_moments=["thing"])
    system = req.messages[0].content.lower()
    # Spot-check the binding voice rules from docs/04.
    assert "second person" in system
    assert "3 to 5 sentences" in system or "3-5" in system or "five sentences" in system
    assert "no clinical terms" in system
    assert "no archetypes" in system


def test_prompt_user_message_includes_template_id_and_summary(
    templates: tuple,
) -> None:
    template = _find_template(templates, "secure-attachment-prominent")
    req = build_prompt(template, signal_moments=["one"])
    user = req.messages[1].content
    assert template.id in user
    assert template.summary in user


def test_prompt_user_message_lists_signal_moments(templates: tuple) -> None:
    template = _find_template(templates, "high-openness")
    moments = ["the unfamiliar word", "the side street"]
    req = build_prompt(template, signal_moments=moments)
    user = req.messages[1].content
    for moment in moments:
        assert moment in user


def test_prompt_user_message_lists_voice_notes(templates: tuple) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(template, signal_moments=["moment"])
    user = req.messages[1].content
    if template.voice_notes.notes:
        assert template.voice_notes.notes[:30] in user
    if template.voice_notes.avoid:
        # At least one avoid phrase should be quoted in the user prompt.
        assert any(p in user for p in template.voice_notes.avoid)


def test_prompt_user_message_includes_exemplar_when_present(
    templates: tuple,
) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(template, signal_moments=["moment"])
    user = req.messages[1].content
    assert template.exemplars[0].output[:30] in user


def test_prompt_trait_summary_renders_high_low(templates: tuple) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(
        template,
        signal_moments=["m"],
        big_five=(0.8, -0.6, 0.0, 0.0, 0.0),
    )
    user = req.messages[1].content
    assert "OCEAN-O high" in user
    assert "OCEAN-C low" in user


def test_prompt_trait_summary_quiet_dimensions_omitted(templates: tuple) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(
        template,
        signal_moments=["m"],
        big_five=(0.1, 0.2, -0.1, 0.0, 0.0),
    )
    user = req.messages[1].content
    # No bipolar dim reached |0.4|, so no direction should be present
    # in the trait summary section. The fallback phrase is used.
    assert "(quiet" in user or "OCEAN-O high" not in user


def test_prompt_metadata_carries_template_id(templates: tuple) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(template, signal_moments=["m"])
    assert req.metadata["template_id"] == template.id
    assert req.metadata["template_version"] == str(template.version)


def test_prompt_empty_moments_fallback_text_in_user_message(
    templates: tuple,
) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(template, signal_moments=())
    user = req.messages[1].content
    assert "no specific moments supplied" in user


def test_prompt_includes_temperature_and_max_tokens(templates: tuple) -> None:
    template = _find_template(templates, "high-openness")
    req = build_prompt(
        template,
        signal_moments=["m"],
        max_output_tokens=400,
        temperature=0.5,
    )
    assert req.max_output_tokens == 400
    assert req.temperature == 0.5
