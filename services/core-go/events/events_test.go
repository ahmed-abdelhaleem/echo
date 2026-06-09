package events

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestChoiceZeroValueRoundTrips(t *testing.T) {
	c := Choice{
		PlaythroughID: "pt-1",
		VignetteID:    "vignette-001",
		ChoiceID:      "choice-1",
		SelectedAt:    time.Unix(1700000000, 0).UTC(),
		HesitationMS:  1200,
	}
	require.Equal(t, "vignette-001", c.VignetteID)
}
