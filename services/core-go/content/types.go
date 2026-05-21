// Package content owns the in-process domain of authored narrative content:
// the Season -> Act -> Vignette -> Choice -> TraitWeight tree authored under
// /content/seasons/ in this repo. The types here are the canonical Go
// projection of packages/content-schema/*.schema.json; both sides must move
// together.
//
// Loading is intentionally separate (see loader.go) so the service can be
// swapped from filesystem to a database-backed loader in M2 without
// touching call sites.
package content

// Season is a complete narrative arc consisting of exactly four Acts. The
// id MUST match `^season-[0-9]{3,}$` (validated at load time by the
// content-validator; we do not re-validate here).
type Season struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Locale      string `json:"locale"`
	Version     int    `json:"version"`
	Description string `json:"description,omitempty"`
	Acts        []Act  `json:"acts"`
}

// Act is a thematic block of vignettes. Echo Seasons always have exactly
// four acts in the order Morning, Midday, Afternoon, Evening
// (docs/04_Game_Design.md §"Acts and pacing").
type Act struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"` // Morning | Midday | Afternoon | Evening
	Vignettes []Vignette `json:"vignettes"`
}

// Vignette is a single decision moment.
type Vignette struct {
	ID              string            `json:"id"`
	SettingBeat     string            `json:"setting_beat"`
	AmbientAudio    *string           `json:"ambient_audio,omitempty"`
	AmbientArt      *string           `json:"ambient_art,omitempty"`
	Choices         []Choice          `json:"choices"`
	ResolutionBeats map[string]string `json:"resolution_beats,omitempty"`
}

// Choice is one option presented within a Vignette.
type Choice struct {
	ID      string        `json:"id"`
	Label   string        `json:"label"`
	Weights []TraitWeight `json:"weights"`
}

// TraitWeight is the signed contribution a Choice makes to a single trait
// dimension. Aggregated linearly across a playthrough by the trait scoring
// engine (T-ML-010).
type TraitWeight struct {
	Dimension TraitDimension `json:"dimension"`
	Delta     float64        `json:"delta"`
	Rationale string         `json:"rationale,omitempty"`
}

// TraitDimension is a stable, content-author-facing identifier for one
// dimension of the trait vector. The enum is mirrored in
// packages/content-schema/trait_weight.schema.json — both sides must change
// together.
type TraitDimension string

// Big Five (OCEAN) dimensions.
const (
	TraitOceanOpenness          TraitDimension = "OCEAN-O"
	TraitOceanConscientiousness TraitDimension = "OCEAN-C"
	TraitOceanExtraversion      TraitDimension = "OCEAN-E"
	TraitOceanAgreeableness     TraitDimension = "OCEAN-A"
	TraitOceanNeuroticism       TraitDimension = "OCEAN-N"
)

// Schwartz value dimensions.
const (
	TraitSchwartzSelfDirection TraitDimension = "SCH-SELF_DIRECTION"
	TraitSchwartzStimulation   TraitDimension = "SCH-STIMULATION"
	TraitSchwartzHedonism      TraitDimension = "SCH-HEDONISM"
	TraitSchwartzAchievement   TraitDimension = "SCH-ACHIEVEMENT"
	TraitSchwartzPower         TraitDimension = "SCH-POWER"
	TraitSchwartzSecurity      TraitDimension = "SCH-SECURITY"
	TraitSchwartzConformity    TraitDimension = "SCH-CONFORMITY"
	TraitSchwartzTradition     TraitDimension = "SCH-TRADITION"
	TraitSchwartzBenevolence   TraitDimension = "SCH-BENEVOLENCE"
	TraitSchwartzUniversalism  TraitDimension = "SCH-UNIVERSALISM"
)

// Attachment proxy dimensions.
const (
	TraitAttachmentSecure   TraitDimension = "ATT-SECURE"
	TraitAttachmentAnxious  TraitDimension = "ATT-ANXIOUS"
	TraitAttachmentAvoidant TraitDimension = "ATT-AVOIDANT"
)

// AllDimensions is the canonical, ordered list of every trait dimension Echo
// scores. Useful for trait-vector aggregation and for tests that need to
// touch each dimension. Order matches the JSON Schema enum.
var AllDimensions = []TraitDimension{
	TraitOceanOpenness, TraitOceanConscientiousness, TraitOceanExtraversion,
	TraitOceanAgreeableness, TraitOceanNeuroticism,
	TraitSchwartzSelfDirection, TraitSchwartzStimulation, TraitSchwartzHedonism,
	TraitSchwartzAchievement, TraitSchwartzPower, TraitSchwartzSecurity,
	TraitSchwartzConformity, TraitSchwartzTradition, TraitSchwartzBenevolence,
	TraitSchwartzUniversalism,
	TraitAttachmentSecure, TraitAttachmentAnxious, TraitAttachmentAvoidant,
}
