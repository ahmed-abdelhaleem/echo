package playthrough

import "testing"

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

