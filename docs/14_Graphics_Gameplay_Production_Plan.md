# 14 — Graphics & Gameplay Production Plan

> Authoritative production plan for turning Echo's Unity proofs into a
> high-quality game. The first vertical slice is **What Remains** (Bedroom).

## Product decision

Echo will use **grounded cinematic realism in compact playable micro-scenes**.
It will not chase photorealism at the cost of uncanny faces, performance, or a
coherent visual identity. Human proportions, recognizable real-life objects,
physically based materials, believable wear, motivated lighting, restrained
post-processing, and natural animation are mandatory. Primitive geometry is
allowed for collision and greyboxing only; it is not final visible art.

The old orbit-only runtime-primitive bootstrap is a prototype harness, not the
production scene architecture. Production vignettes are authored Unity scenes
or prefabs with explicit gameplay state, asset provenance, budgets, lighting,
camera bounds, accessibility behavior, and tests.

## Player experience contract

Each embodied vignette lasts roughly two to four minutes:

1. A short setting beat establishes who the player is and what just happened.
2. The player walks within one bounded real place.
3. One immediate objective points toward the dramatic setup.
4. Two or three contextual interactions reveal the situation.
5. Optional noticing points reward attention without affecting scoring.
6. The trait-bearing choice is made in context.
7. A brief physical and narrative resolution closes the vignette.

There is no combat, platforming, health, timer, fail state, grind, or inventory
puzzle. A clearly labelled accessibility control can skip embodied setup and go
to the choice without penalty.

## First vertical slice: What Remains

**Role:** The player controls Noor inside their bedroom on a rainy evening.

**Dramatic question:** A trusted person has asked whether Noor is okay while a
half-packed suitcase and an old photograph make the truthful answer difficult.

**Playable sequence:**

1. Start beside the unmade bed. Objective: **Find the photograph.**
2. Walk with WASD/left stick; mouse/right stick controls a damped follow camera.
3. Interact with the framed photograph on the nightstand.
4. The phone on the desk becomes the next objective: **Read the message.**
5. Optional interactions: rain-streaked window, chipped mug, suitcase, bed.
6. Interact with the phone and choose **Answer honestly** or **Say you're fine**.
7. Lighting, character posture, narration, and phone state acknowledge the
   choice. The player can replay the vignette or return to the proof-scene hub.

**Controls:**

- WASD / left stick: move
- Mouse / right stick: look
- E / south gamepad button: interact
- Escape: pause
- R: restart the vignette
- “Skip to choice”: always available from the objective panel

## Graphics quality bar

### Environments

- Real-world scale in metres; door, furniture, reach, and camera heights are
  checked against the character.
- PBR base colour, normal, roughness/smoothness, metallic where applicable.
- Bevels or authored edge normals on all hero hard-surface silhouettes.
- No visible primitive placeholders, floating props, z-fighting, unintentional
  texture repetition, or unlit black surfaces.
- Every room has a composition hierarchy: hero story object, secondary path,
  background dressing, and negative space for the character/camera.
- Lived-in detail is authored, not scattered randomly.

### Characters

- One consistent base topology/rig family per Season where practical.
- Proper humanoid rig, foot contact, root-motion policy, idle/walk/turn,
  interaction pose, facial look direction, and material QA.
- Mixamo is acceptable for the free vertical slice and animation prototyping.
  Raw Mixamo files remain local with a reproducible import recipe.
- Final paid quality recommendation: a character artist using Reallusion
  Character Creator/ActorCore or an equivalent licensed Unity-ready pipeline,
  followed by manual Blender cleanup and scene-specific animation polish.
- Faces are kept at natural conversational distance; do not use extreme closeups
  until facial animation reaches the quality bar.

### Lighting and rendering

- URP Forward+, baked/mixed global illumination where target-appropriate.
- Motivated key light, soft fill, window/rim separation, reflection probes,
  light probes for characters, contact shadows, ambient occlusion, restrained
  bloom, filmic tone mapping, and calibrated exposure.
- The Bedroom palette is cool rain-blue ambient light against one warm practical
  lamp. Choice feedback adjusts the balance subtly; it never turns into a moral
  “good/bad” colour code.
- One authored still framing per vignette is the reduce-motion and low-tier
  fallback.

### Camera and UI

- Third-person camera collision, bounded yaw/pitch, capped velocity, no forced
  shake, and no automatic motion when Reduce Motion is enabled.
- Interaction prompts live near the action but maintain readable contrast.
- Objective and choice UI use safe areas and scale from mobile through desktop.
- On-screen text never competes with the character's head or the hero object.

### Audio

- Room tone, rain, cloth/footstep surfaces, phone vibration, lamp/electrical
  detail, interaction one-shots, and a restrained resolution sting.
- All audio assets require the same source/license/provenance gate as models.
- The game remains fully understandable without audio; captions describe
  story-bearing sounds.

## Vetted free asset set for the three-scene slice

All environment assets below are downloaded at 1K from Poly Haven and are CC0:

| Scene role | Asset slug |
|---|---|
| Bed | `vintage_day_bed` |
| Nightstand | `side_table_01` |
| Reading chair | `modern_arm_chair_01` |
| Desk | `metal_office_desk` |
| Desk lamp | `desk_lamp_arm_01` |
| Notebook | `binder_notebook` |
| Plant | `potted_plant_01` |
| Photograph | `standing_picture_frame_01` |
| Half-packed luggage | `vintage_suitcase` |
| Clock | `alarm_clock_01` |
| Books | `decorative_book_set_01` |
| Wardrobe/cabinet | `modern_wooden_cabinet` |
| Street lamps | `street_lamp_01` |
| Plaza seating | `modular_street_seating` |
| Bus-stop bench | `painted_wooden_bench` |
| Street bin | `metal_trash_can` |
| Café tables | `round_wooden_table_01` |
| Café chairs | `dining_chair_02` |
| Café pendants | `hanging_industrial_lamp` |

Source manifest and reproducible downloader:
`apps/unity-client/tools/assets/`. The asset gate verifies checksums, format,
license, dimensions, triangle counts, materials, texture sizes, and render QA.

The free player-character recipe uses Mixamo **Remy** with an in-place Walking
clip. Adobe states that Mixamo characters and animations may be used
royalty-free in video games. The raw FBX is local and ignored.

## Whole-game environment strategy

Season 1's 15–25 vignettes are built from five reusable environment families:

1. **Apartment:** bedroom, kitchen, hall, bathroom, balcony.
2. **Street and transit:** shopfront street, crossing, bus stop, bus interior.
3. **Café and small retail:** counter, seating, kitchen/storage, doorway.
4. **School/workplace:** corridor, classroom/studio, desk cluster, break area.
5. **Waterfront/park:** promenade, shelter, bench, small plaza, overlook.

Each family owns a modular architecture kit, prop library, surface-material set,
lighting presets, audio palette, collision/navigation setup, and tested camera
profiles. Vignettes reuse the kit but change dressing, weather, time, people,
story objects, routes, and interaction states so reuse never feels like a copied
level.

## Performance budgets

Initial per-vignette targets, verified on representative hardware:

| Budget | Desktop/macOS | Mid-range mobile | WebGL/low tier |
|---|---:|---:|---:|
| Visible triangles | 1,000,000 | 350,000 | 180,000 |
| Skinned triangles | 160,000 | 80,000 | 45,000 |
| Materials visible | 80 | 45 | 28 |
| Main texture memory | 350 MB | 160 MB | 90 MB |
| Dynamic shadow lights | 2 | 1 | 0–1 |
| Target frame rate | 60 | 30–60 | 30 |

Every hero model gets an LOD plan. Scan-heavy foliage and book sets are
decimated or replaced before mobile sign-off. Textures default to 1K for props,
2K for hero objects, and atlas/trim sheets for repeated architecture.

## Production architecture

- `VignetteDirector`: owns deterministic vignette state and transitions.
- `ThirdPersonController`: movement, collision, grounding, animation speed.
- `ThirdPersonCamera`: follow/orbit, collision, input, Reduce Motion.
- `Interactable`: prompt, range, action identifier, optional/required status.
- `InteractionResolver`: selects the nearest visible valid interaction.
- `ObjectivePresenter`: one immediate dramatic intention, skip-to-choice route.
- `ChoicePresenter`: accessible 2–4 option UI and deterministic result event.
- `SceneArtProfile`: lighting, post, audio, fallback still, performance tier.
- `AssetProvenance`: source, license, checksum, author, import settings, budgets.

Gameplay state is independent of rendering. Missing high-quality assets select a
deliberate fallback but never break the vignette. Exploration events are not
fed into trait scoring without a separately reviewed calibration change.

## Asset and scene gates

An asset cannot enter a production scene until it passes:

1. License/provenance and redistribution check.
2. Malware/file-format and checksum validation.
3. Scale, pivot, UV, normals, material, and naming validation.
4. Triangle/material/texture budget check with LODs where required.
5. In-engine render review under the scene's actual lighting.
6. Collision, occlusion, accessibility, brand, and youth-safe review.

A vignette cannot pass the vertical-slice gate until:

- A first-time player can finish without instruction.
- Movement and camera feel intentional on keyboard/gamepad and touch plan.
- The story is understandable with audio muted.
- The choice is reachable through both play and accessibility skip.
- No placeholder geometry is visible.
- The target frame-time and memory budget pass.
- External reviewers agree the room feels inhabited and emotionally specific.

## Real-world scale intake procedure

Every visible 3D model now follows the same measurable intake path. Screenshot
judgment remains required, but it is the final check rather than the first place
that scale errors are discovered.

1. Add the source slug to the vetted CC0 download manifest.
2. Add exactly one semantic entry to
   `Assets/Resources/Config/real_world_scale_profiles.json`: category, intended
   longest dimension in metres, and a valid in-scene height range.
3. Run `make unity-fetch-bedroom-assets` and
   `make unity-validate-bedroom-assets`. Blender rejects missing profiles,
   invalid ranges, empty meshes, and implausible source dimensions.
4. Place the object only through `CreatePolyHavenModel`. Runtime import
   uniformly normalizes the renderer bounds to the declared metre target,
   grounds the lowest visible point, and attaches an `EchoScaleAudit`.
5. Use the 1.78 m player profile as the scene reference. The same runtime gate
   normalizes the character visual; furniture is never scaled by eye against an
   unknown-size avatar.
6. Run `make unity-test`. Play-mode coverage rejects target-dimension drift,
   wrong-axis imports, semantic-height failures, missing audits, floating
   placement, and broken character proportions.
7. Build and inspect the standalone from the intended player camera. Review
   reach height, seat height, clearance, collision, occlusion, and composition;
   record the result in `docs/13_Agent_Change_Log.md`.

Do not compensate for a bad import by repeatedly editing scene scale values.
Correct the shared profile or the import orientation, then rerun the gates so
every use of that asset receives the same fix.

## Delivery sequence

1. Complete **What Remains** as the quality/reference slice.
2. External art-direction, gameplay, accessibility, and youth-safe review.
3. Revise the production kit until the slice passes.
4. Rebuild Café and Street using the approved systems and quality bar.
5. Lock the five reusable environment families.
6. Produce remaining Season scenes in small reviewed batches.
7. Run platform performance, accessibility, content, and trait-replay gates.

**Current implementation note (2026-07-28):** Street and Café have been moved
onto the reusable third-person/objective/choice architecture early so the
system can be tested as a connected game loop. That engineering proof does not
declare the Bedroom quality gate passed and does not authorize bulk production.
One excellent, externally approved slice remains more valuable than twenty
primitive dioramas.
