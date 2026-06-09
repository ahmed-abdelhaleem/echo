package playthrough

import (
	"errors"
	"testing"
)

func TestFindDivergenceMoment_NoDivergence_ReturnsError(t *testing.T) {
	canonical := []string{"vignette-001", "vignette-002"}

	// Both players chose the same option on every vignette.
	choicesA := []ChoiceEvent{
		{VignetteID: "vignette-001", ChoiceID: "choice-a"},
		{VignetteID: "vignette-002", ChoiceID: "choice-b"},
	}
	choicesB := []ChoiceEvent{
		{VignetteID: "vignette-001", ChoiceID: "choice-a"},
		{VignetteID: "vignette-002", ChoiceID: "choice-b"},
	}

	_, err := findDivergenceMoment(canonical, choicesA, choicesB)
	if err == nil {
		t.Fatal("expected ErrNoDivergence, got nil")
	}
	if !errors.Is(err, ErrNoDivergence) {
		t.Fatalf("expected ErrNoDivergence, got %v", err)
	}
}

func TestFindDivergenceMoment_SkipsVignettesMissingFromEitherPlayer(t *testing.T) {
	canonical := []string{"vignette-001", "vignette-002", "vignette-003"}

	// Player A only answered vignette-002 and vignette-003.
	// Player B only answered vignette-001 and vignette-003.
	// Only vignette-003 is answered by both, and there they diverge.
	choicesA := []ChoiceEvent{
		{VignetteID: "vignette-002", ChoiceID: "choice-x"},
		{VignetteID: "vignette-003", ChoiceID: "choice-a"},
	}
	choicesB := []ChoiceEvent{
		{VignetteID: "vignette-001", ChoiceID: "choice-x"},
		{VignetteID: "vignette-003", ChoiceID: "choice-b"},
	}

	divergence, err := findDivergenceMoment(canonical, choicesA, choicesB)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if divergence.VignetteID != "vignette-003" {
		t.Fatalf("expected vignette-003, got %s", divergence.VignetteID)
	}
}

func TestFindDivergenceMoment_UsesCanonicalVignetteOrder(t *testing.T) {
	canonical := []string{"vignette-001", "vignette-002", "vignette-003"}

	choicesA := []ChoiceEvent{
		{VignetteID: "vignette-002", ChoiceID: "choice-a"},
		{VignetteID: "vignette-001", ChoiceID: "choice-a"},
		{VignetteID: "vignette-003", ChoiceID: "choice-a"},
	}
	choicesB := []ChoiceEvent{
		{VignetteID: "vignette-002", ChoiceID: "choice-b"},
		{VignetteID: "vignette-001", ChoiceID: "choice-b"},
		{VignetteID: "vignette-003", ChoiceID: "choice-a"},
	}

	divergence, err := findDivergenceMoment(canonical, choicesA, choicesB)
	if err != nil {
		t.Fatalf("findDivergenceMoment: %v", err)
	}

	if divergence.VignetteID != "vignette-001" {
		t.Fatalf("vignette id: want vignette-001, got %s", divergence.VignetteID)
	}
	if divergence.InviterChoice != "choice-a" || divergence.InviteeChoice != "choice-b" {
		t.Fatalf("unexpected choices: %+v", divergence)
	}
}
