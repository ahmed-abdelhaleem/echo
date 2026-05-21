# 04 — Game Design Document

## Design pillars

Every gameplay decision must serve at least one of three pillars. If a feature serves none, it doesn't ship.

1. **Honesty by indirection.** The player reveals more by playing a character than by being asked about themselves.
2. **Calm intentional pacing.** Every moment is deliberate. No urgency, no streaks, no pressure. The game protects attention rather than steals it.
3. **A result worth keeping.** The output is beautiful, specific, and shareable. The player wants to screenshot it.

---

## The playthrough — structural anatomy

### Shape of a Season

A Season is **one fictional day**, divided into four **Acts**:

| Act | Theme | Vignettes | Purpose |
|---|---|---|---|
| Morning | Setup & instinct | 4–6 | Baseline behavior, first reactions, how the character treats time and space when alone |
| Midday | Social texture | 4–6 | How the character relates to known others — friends, family, coworkers |
| Afternoon | Pressure & ambiguity | 4–6 | A complication arrives. Multiple plausible responses. The most diagnostic act. |
| Evening | Resolution & reflection | 3–5 | What the character chooses to carry, let go, or notice as the day ends |

Total: **15–25 vignettes** per Season. Target playtime: **20–30 minutes** uninterrupted, but explicitly designed for paused/resumed play.

### Shape of a Vignette

Each vignette is a single screen with this structure:

1. **Setting beat** — 1–3 sentences of present-tense narration that places the character in a specific moment. May include an evocative still image and ambient audio layer. No "you are in a forest" generic flavor — every setting is specific (*"The kitchen light is on. Someone has been crying recently and pretended not to."*).
2. **Inciting choice** — 2 to 4 options, each phrased in natural language as something a person would actually do or say. No labels, no MBTI-coded options.
3. **Resolution beat** — 1–2 sentences acknowledging the choice. Never judgmental. Sometimes the resolution carries forward and influences a later vignette; sometimes it doesn't.

**Critical:** the player is never told which choices "count" or which traits are being measured. They aren't. *All* choices count, including the act of skipping ambient interactions.

### Hidden signals

The trait engine reads more than just final choices. It reads:

- **Selection** — which option the player picked.
- **Hesitation time** — how long they spent before selecting.
- **Hover / revisit** — whether they considered another option, then went back.
- **Pacing** — whether they linger on setting beats or rush through them.
- **Pattern across acts** — whether they're consistent or shift behavior under pressure.

The player is not told this. But the privacy summary discloses it, and the result acknowledges it indirectly (*"You change when you think no one is watching, but only slightly."*).

---

## The trait model — what we actually measure

Echo uses a **layered trait model**. The deeper layers are not exposed to the player by default; they exist for the trait engine and (under proper consent) for B2B research applications.

### Layer 1 — Big Five (OCEAN)
The scientific backbone. Used because it is the most validated trait framework in personality psychology and the one institutional buyers will accept.

- **O** — Openness to Experience
- **C** — Conscientiousness
- **E** — Extraversion
- **A** — Agreeableness
- **N** — Neuroticism (referred to as *Emotional Reactivity* in player-facing language, never with the clinical label)

Each playthrough produces a 5-vector. Sub-facets (e.g. Openness → curiosity vs. aesthetics) are tracked but not displayed at MVP.

### Layer 2 — Schwartz Basic Human Values
Adds *motivational* nuance on top of trait dispositions. 10 dimensions, used in academic research and increasingly in HR assessment:
- Self-Direction, Stimulation, Hedonism, Achievement, Power, Security, Conformity, Tradition, Benevolence, Universalism.

These map well onto the kinds of choices Echo's vignettes naturally generate (do you protect a stranger's feelings? do you tell a hard truth? do you take an opportunity that costs someone else?).

### Layer 3 — Attachment style proxies
Three behavioral signals approximated from in-game choices, never claimed as clinical assessment:
- Secure / Anxious / Avoidant patterns in social vignettes.
- These inform the prose reflection but are *never* exposed as labels to under-18 players.

### Layer 4 — Echo-native dimensions (over time)
Once we have data at scale, we'll discover Echo-native dimensions that don't map cleanly to any existing framework. These become a research contribution. They are not in the MVP scope but the data architecture supports them from day one.

---

## The Portrait — how it's generated

The Portrait is *parametric* visual art, deterministically generated from the Trait Vector + a per-player seed. It is **not** AI-image-generated at MVP (cost, latency, brand inconsistency).

### Visual mapping (illustrative — exact tuning during build)

| Trait input | Visual parameter |
|---|---|
| Openness | Color palette warmth and variance, motif complexity |
| Conscientiousness | Composition order, geometric vs. organic |
| Extraversion | Density of elements, presence of "other" shapes |
| Agreeableness | Soft vs. hard edges, palette harmony |
| Emotional Reactivity | Movement and texture quality, contrast |
| Schwartz values | Symbolic motifs (curated library of shapes mapped to value clusters) |
| Attachment proxies | Spatial relationships between elements (proximity, overlap, isolation) |

A Portrait is rendered in two formats:
- **Animated** — a 6–10 second looped piece for in-app and Story sharing.
- **Static** — a 1080×1080 square and 1080×1920 vertical for feed and Story sharing.

Style direction reference points: the work of Hilma af Klint, the chromatic studies of Olafur Eliasson, the typographic compositions of Studio Dumbar. **Restrained, evocative, unmistakable.** A friend should be able to recognize an Echo Portrait at a glance.

---

## The prose reflection

3–5 sentences. Second person. Never clinical. Always specific.

### Generation pipeline

1. **Input.** Trait Vector + a small set of "signal moments" — specific vignettes where the player made a strongly diagnostic choice.
2. **Template selection.** From a library of ~50 voice-tested reflection templates, one or a blend is selected based on the trait vector.
3. **LLM completion.** A constrained prompt fills the template with player-specific specifics, using the signal moments to ground the language.
4. **Safety + tone classifier.** The output passes through:
   - **Safety filter** — no clinical diagnostic language, no content interpretable as self-harm triggering, age-appropriate for under-18.
   - **Tone classifier** — confirms it is generous, specific, and recognizably Echo's voice. Rejects generic or flattering outputs.
5. **Fallback.** If safety or tone fails, a curated pre-written fallback reflection is used and the failure is logged for review.

### Voice rules (enforced via prompt + classifier)

- **Always second person.** "You..." never "the user" or "this person."
- **Always specific.** A reflection that could describe anyone is a failed reflection.
- **Never flattering, never roasting.** Echo describes; it does not evaluate.
- **No clinical terms.** No "neurotic," "narcissistic," "avoidant," "depressed."
- **No archetypes.** No "you are the helper," "you are the rebel."
- **Acknowledge contradiction.** Real people are contradictory; the reflection should be too where the data supports it.

### Example reflections (illustrative target quality)

> *"You notice exits before you notice people. You give second chances quietly, without announcing them. When the day asked you to choose between being kind and being honest, you tried to do both, and the small bruise of that compromise is what you'll remember tonight."*

> *"You are not actually the careful one — you only look that way because you decide quickly. The two things you would not let go of today were the song you played alone and the message you didn't send. Both of those decisions were the same decision."*

Note that these are not horoscope-vague. They reference specific in-game moments, in a way that the player will recognize.

---

## Replayability and the "trying to game it" problem

A real risk: players will try to play the game *as a particular kind of person* to see what Portrait results.

**Echo's design response is to lean into this.** Re-playing the Season with deliberately different choices is a feature, not a leak. The Portrait changes, and the player learns something genuine about their own values by watching their own attempts to manipulate the result.

Mechanics:
- Each playthrough is saved. The player can see a small "constellation" of all their Portraits.
- A subtle UI hint after the third playthrough reflects: *"The fact that you played three times tells me something too."* (Tone-calibrated, never accusatory.)

---

## Friend comparison (V1)

The single mechanic with the strongest viral potential.

### How it works
- Two players have both completed the same Season.
- One sends a comparison invite to the other.
- Both must explicitly accept.
- Both see their Portraits side-by-side, plus **one chosen vignette where their choices diverged** — written specifically for the comparison.

### Why one vignette and not all of them?
Showing all divergences would feel surveillance-y, and would reveal too much. Showing exactly one — chosen by the engine for being maximally illustrative of personality difference, not maximally embarrassing — is the right amount of intimate.

### The shareable artifact
Comparison produces a single composite image (e.g. two Portraits + a one-line excerpt). The composite has a watermark and a link back to Echo. This is the strongest viral artifact in the product.

---

## Content production — what it actually takes

This is where the founder's stated strength ("constant ability to enhance the features with time") is most directly the moat.

### Writing one Season
- **Concept and arc:** 1–2 weeks of writing-room work.
- **Vignette drafting:** 20 vignettes × ~2 hours each = ~40 hours.
- **Trait weight tagging:** every choice in every vignette gets weights, reviewed against the trait model. ~10 hours.
- **Internal playtesting:** 20–30 testers × the Season; results reviewed for trait validity, vignette pacing, and "is the result recognizable?" — typically 2 cycles of revision = 60–80 hours.
- **Art, audio, polish.** Variable, ~60–100 hours.

**Total: 150–250 hours per Season.** Two-person team output, roughly one Season per quarter sustainable.

### Calibration against validated assessments
Periodically (target: every other Season), a willing subset of beta testers also completes a Big Five inventory (BFI-2 is open-license and well-validated). Echo's predicted trait vectors are compared against the BFI-2 results to keep the engine honest. This is also the data that supports the eventual ML-augmented trait engine in V2.

---

## Failure modes to design against

- **Result feels too generic.** Failure of the prose pipeline. Mitigated by the tone classifier and the requirement to ground in signal moments.
- **Result feels invasive or upsetting.** Failure of brand voice and youth-safe filtering. Mitigated by safety classifier, stricter under-18 filtering, and the option to "set this Portrait aside" rather than dismiss it.
- **Choice feels forced.** Failure of vignette writing. Mitigated by extensive playtesting; every vignette must have at least one tester who chose each option without it feeling wrong.
- **Trait engine over-fits to the choice surface.** Failure of calibration. Mitigated by cross-validation against BFI-2 and other inventories with consenting users.
