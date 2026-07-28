# 13 — Agent Change Log

> **Living log of changes made by AI agents.** It is the fast way for the next agent (or human) to see *what just changed* and *what is queued next* without re-reading every doc or the full git history. It complements — does not replace — git history and the task tracker.

## How agents must maintain this file (binding)

At the **end of any change**, every AI agent MUST:

1. **Prepend a new entry** to *Change log* (newest first) using the template below: date (UTC), agent, a one-line summary, the area(s), the key files/docs touched, and any human-review / escalation flags.
2. **Update *Next in pipeline*** so it references the single next change expected — or `— none queued —` if nothing is.
3. Keep it terse. This is a pointer index, not a design doc — link to the authoritative doc/task (`F-…`, `T-…`, `Mn`) instead of restating it.

This rule is also stated in `AGENTS.md` and `07_AI_Agent_Implementation_Guide`; conformance is expected on every agent change.

**Entry template**

```
### YYYY-MM-DD · <agent> · <one-line title>
- What changed and why (1–4 bullets). Link tasks/features/milestones.
- Files/docs: <paths>.
- Flags: <human-review-required / escalation # / none>.
```

---

## Next in pipeline

> A single reference to the next change. Replace it when you pick up the next thing.

- Run an external first-time-player/art-direction/accessibility/youth-safe review
  of the connected Bedroom → Street → Café build; use the findings to revise
  the reference kit before producing the next Apartment-family vignette.

---

## Change log

### 2026-07-28 · Codex · Unity source-versus-generated Git audit
- Audited all 643 status entries: 631 are intentional Unity project/source
  files, including 195 MB of redistributable CC0 art and required `.meta`
  identities. No currently untracked cache, log, test result, or build output
  remains eligible for commit.
- Confirmed Unity Library (2.5 GB), standalone builds (296 MB), logs, test
  results, user settings, and generated IDE files are ignored; added guards for
  exported objects/packages, platform binaries, crash diagnostics, and IDE
  state.
- Kept raw Noor/YBot Mixamo FBX files and their metas ignored because the game
  license permits use but not redistribution of the downloadable source files.
- Files/docs: `apps/unity-client/.gitignore`,
  `docs/13_Agent_Change_Log.md`.
- Flags: none. No assets deleted; all redistributable assets used by the game
  remain eligible to push.

### 2026-07-28 · Codex · Enforced real-world scale gate for characters, props, and rooms
- Added one authoritative metre-scale profile catalog for all 20 vetted
  environment models and the 1.78 m player reference. Runtime construction now
  normalizes and grounds imported bounds, derives padded collision for blocking
  furniture, and attaches testable scale evidence.
- Blender rejects missing/invalid asset profiles; play-mode coverage rejects
  target drift, wrong-axis heights, missing audits, and oversized architecture.
  It also proves the player cannot cross the suitcase collider. Added
  `make unity-validate-scale` as the single model-intake gate.
- Recalibrated the Bedroom from a 12 × 9.5 × 6 m shell to a believable
  residential volume, corrected furniture/hero-prop placement, tightened the
  follow camera, and added a ceiling. Unity tests, Blender validation, and the
  macOS build pass; the rebuilt standalone was visually reviewed and left open.
- Files/docs: `apps/unity-client/Assets/{Resources/Config,Scripts/EchoPrototype,Tests/PlayMode}`,
  `apps/unity-client/tools/blender/inspect_polyhaven_assets.py`,
  `apps/unity-client/README.md`, `Makefile`, `docs/{13,14}_*.md`.
- Flags: **human-review-required** for Unity dependency/client direction and
  scene asset/brand/youth-safe gate (#1/#7/#12). No paid API, account, secret,
  trait-scoring, classifier, or redistributed Mixamo raw-file change.

### 2026-07-28 · Codex · Bedroom layout and third-person locomotion repair
- Replaced the misleading tipped daybed with an upright, grounded CC0 sofa;
  repositioned the chair, nightstand, alarm clock, suitcases, and interaction
  anchors; and added a deliberately visible gold/red photograph surface.
- Corrected the Mixamo visual forward axis, replaced instantaneous direction
  snaps with acceleration and bounded turn rates, blended walk/idle playback,
  and synthesized a centered fallback stance from opposite walk phases.
- Added layout and gradual-turn regressions; Unity play-mode tests and macOS
  build pass. The rebuilt standalone was inspected and played with W/D, and is
  left running. Trait scoring is unchanged.
- Files/docs: `apps/unity-client/Assets/{Scripts/EchoPrototype,Tests/PlayMode,Resources/Art/PolyHaven/chinese_sofa}`,
  `apps/unity-client/tools/assets/polyhaven_bedroom_assets.json`,
  `docs/13_Agent_Change_Log.md`.
- Flags: **human-review-required** for Unity dependency/client direction and
  scene asset/brand/youth-safe gate (#1/#7/#12). No paid API, account, secret,
  trait-scoring, classifier, or redistributed Mixamo raw-file change.

### 2026-07-28 · Codex · Movement, visible real-scale props, and three-vignette playable loop
- Fixed keyboard movement so both held keys and short key presses reliably move
  the character; added explicit in-game controls, faster walking, testable
  movement, and a regression test that asserts visible translation.
- Fixed mixed FBX centimetre/metre and Z-up imports with bounds-driven
  normalization and placement. The bed, phone, photograph, street lamps,
  benches, tables, chairs, and pendants now appear at grounded real-world scale;
  the Bedroom bed was recomposed to show its full silhouette.
- Converted Harbor Street and Saffron Café from orbit proofs to the reusable
  third-person objective/interaction/choice/ending architecture, connected all
  three scenes into a continuous loop, and added seven vetted CC0 environment
  assets for Street/Café. Trait scoring is unchanged.
- Verified: 19-model Blender asset audit passes; Unity play-mode test completes
  all three required routes and endings; macOS build succeeds; standalone
  movement and every scene transition were visually exercised; final
  `Player.log` has no error/exception/failure matches. The rebuilt game is left
  running.
- Files/docs: `apps/unity-client/Assets/{Scripts/EchoPrototype,Tests/PlayMode,Resources/Art/PolyHaven}`,
  `apps/unity-client/tools/assets`, `apps/unity-client/README.md`, `README.md`,
  `docs/{10,13,14}_*.md`.
- Flags: **human-review-required** for Unity dependency/client direction and
  scene asset/brand/youth-safe gate (#1/#7/#12). No paid API, account, secret,
  trait-scoring, classifier, or redistributed Mixamo raw-file change.

### 2026-07-26 · Codex · What Remains converted from viewer to playable 3D reference slice
- Replaced the Bedroom orbit-only proof contract with bounded third-person
  movement, CharacterController/furniture collision, collision-aware follow
  camera, required photograph → phone objectives, world guidance, six
  contextual interactions, pause/restart/no-penalty skip, two-choice ending,
  lighting feedback, and generated rain room tone. Trait scoring is unchanged.
- Integrated and runtime-materialized a reproducibly fetched 12-model, 1K CC0
  Poly Haven Bedroom set; added checksum fetching, Blender scale/triangle
  audits, provenance, and Make targets. Integrated the optional local Mixamo
  Remy character with an ignored raw FBX, checked-in reproduction recipe, URP
  material mapping, and a no-file fallback.
- Rewrote the graphics/gameplay direction around grounded cinematic realism in
  bounded playable micro-scenes, with whole-game environment families, asset
  gates, performance budgets, production components, and a Bedroom-first
  scaling gate. Street and Café are explicitly still older art proofs.
- Verified: all asset checksums ready; all 12 FBXs import in Blender; Unity
  play-mode required-route/ending test passes; macOS `Echo.app` builds (250 MB);
  the final standalone build was exercised through photograph, accessibility
  choice route, honest ending, lighting response, and has no problem matches in
  `Player.log`. The final build is left running.
- Files/docs: `apps/unity-client/Assets/{Scripts/EchoPrototype,Tests/PlayMode,Resources/Art/PolyHaven,Resources/Characters/Noor}`, `apps/unity-client/tools/{assets,blender}`, `apps/unity-client/README.md`, `Makefile`, `README.md`, `docs/{00,03,04,05,06,07,10,13,14}_*.md`.
- Flags: **human-review-required** for the Unity dependency/client direction and
  scene asset/brand/youth-safe gate (#1/#7/#12). No paid API, account, secret,
  trait-scoring, classifier, or redistributed Mixamo raw-file change.

### 2026-07-26 · Codex · Three-scene free Unity proof completed and running
- Added **The Last Table**, a switchable Café/Shop vignette with warm ambient lighting, animated/fallback barista, last guest, espresso and pastry counter, tables, forgotten sketchbook, three optional noticing points, and a non-judgmental two-choice resolution.
- Expanded navigation and automated coverage to Bedroom, Harbor Street, and Café/Shop. Tests pass with the optional local Mixamo FBX present and absent; removed the obsolete template-camera script reference; the rebuilt macOS `Echo.app` was visually exercised across all three scenes, including the Café choice and sketchbook inspection, left running, and has a clean player-log problem scan.
- Updated status documentation: the code-level 3-scene implementation proof is complete, while external art-direction, asset/brand, and youth-safe review remain required before the proof gate passes or production scales.
- Files/docs: `apps/unity-client/Assets/{Scenes/SampleScene.unity,Scripts/EchoPrototype/EchoWorldBootstrap.cs,Tests/PlayMode/EchoWorldBootstrapTests.cs}`, `apps/unity-client/{README.md,Assets/Scripts/EchoPrototype/README.md}`, `README.md`, `docs/10_Roadmap_Milestones.md`, `docs/13_Agent_Change_Log.md`.
- Flags: **human-review-required** for new Unity client/dependencies and scene-level asset QA/brand/youth-safe review (#1/#7/#12). No paid API, secret, trait-scoring, classifier, or redistributed Mixamo asset change.

### 2026-07-26 · Codex · Playable Bedroom proof added to the running Unity game
- Added **What Remains**, a switchable rain-lit bedroom vignette with animated/pacing Noor, unmade bed, desk, chipped mug, window rain, wardrobe, books, plant, three optional noticing points, per-scene bounded camera framing, and a non-judgmental two-choice resolution.
- Added in-game Bedroom/Harbor Street navigation; verified the honest-response branch, scene switching, and chipped-mug inspection in the rebuilt standalone `Echo.app`.
- Expanded the Unity play-mode test to cover both scenes and ≥3 inspectable details; it passes with Mixamo loaded and with the local FBX removed/fallback characters active.
- Files/docs: `apps/unity-client/Assets/Scripts/EchoPrototype/{EchoWorldBootstrap.cs,EchoOrbitCamera.cs,EchoInspectable.cs,README.md}`, `apps/unity-client/Assets/Tests/PlayMode/EchoWorldBootstrapTests.cs`, `apps/unity-client/README.md`, `README.md`, `docs/10_Roadmap_Milestones.md`, `docs/13_Agent_Change_Log.md`.
- Flags: **human-review-required** for scene-level asset QA/brand and youth-safe review (#7/#12). No paid API, secret, trait-scoring, classifier, or redistributed Mixamo asset change.

### 2026-07-26 · Codex · Reproducible free Unity game client running as a standalone build
- Added `apps/unity-client`: Unity 6 Personal/URP harbor-street diorama, bounded camera, independent narrative choice UI, animated Mixamo pedestrian with stylized no-asset fallback, play-mode coverage, macOS build automation, and Blender FBX validation. Built and played `Echo.app`; the choice changed story/lighting and the player log was exception-free.
- Made Unity the authoritative Phase-G client; retired Thermion/Meshy as the final-game direction and documented the Blender + verified CC0 + optional local Mixamo production/licensing workflow. Raw Mixamo downloads and Unity build/cache output remain ignored.
- Made core configuration tests deterministic when a developer's local `.env` explicitly overrides dev-only booleans.
- Kept the legacy Flutter fallback analyzable under current Flutter by disambiguating and explicitly typing Thermion's generic `View`.
- Verified: Blender import (2 meshes, 1 armature, 1 action, 55,320 triangles); Unity play-mode test passes both with and without the local FBX; macOS standalone build succeeds (118 MB).
- Verification note: the legacy Flutter client analyzes and builds for web, but its native test bootstrap still fails inside retired Thermion 0.3.4's Filament C++ link hook; Unity tests/builds are unaffected.
- Files/docs: `apps/unity-client/**`, `apps/client/lib/features/vignette/backdrop/three_d_viewport_io.dart`, `services/core-go/internal/config/config_test.go`, `Makefile`, `README.md`, `docs/03_Product_Requirements.md`, `docs/05_Technical_Architecture.md`, `docs/06_Tech_Stack.md`, `docs/07_AI_Agent_Implementation_Guide.md`, `docs/10_Roadmap_Milestones.md`, `docs/13_Agent_Change_Log.md`.
- Flags: **human-review-required** — new top-level Unity client/dependencies (#1) and scene asset QA/brand gate (#12); youth-safe scene review remains required before shipping (#7/#12). No paid generation APIs, secrets, scoring, or classifier changes.

### 2026-07-26 · Codex · Running Unity Personal street-vignette proof of concept
- Built and live-verified a dependency-free URP street vignette with café, bookshop, apartments, bus stop, plaza, street furniture, six stylized people, three looping pedestrians, bounded camera exploration, and a meaningful Echo choice with lighting feedback.
- Fixed coexistence with the legacy scene by disabling its old-input camera and template volumes at prototype startup; Unity Play Mode now runs with zero errors.
- Files/docs: `/Users/saeed.abdelhalim/echo/Assets/Scripts/EchoPrototype/{EchoWorldBootstrap.cs,EchoOrbitCamera.cs,EchoNpcWalker.cs,README.md}`, `docs/05_Technical_Architecture.md`, `docs/13_Agent_Change_Log.md`.
- Flags: none; no paid APIs, new packages, credentials, or scoring/safety paths touched.

### 2026-07-23 · Antigravity · 3D Content-Production & Rendering Strategy Pivot
- Updated `docs/03`, `05`, `06`, `10`, and `13` to adopt the free/open CC0 asset pipeline (Unity Personal or Godot 4 + GDScript, Blender, Kenney & Poly Haven CC0 assets, Mixamo animations, verified commercial sound libraries).
- Replaced automated AI 3D asset generation (Meshy/TRELLIS) and Thermion/Filament Flutter rendering strategy as the foundation for the final game. Retained Go backend, Python ML/trait engine, writing, and season schemas.
- Instituted the 3-scene proof-of-concept pipeline (Bedroom, Street/Bus Stop, Café/Shop) to prove art direction with external testers ("this feels like a real place") before scaling to the remaining 17 scenes across 5 reusable environments.
- Files: `docs/03_Product_Requirements.md`, `docs/05_Technical_Architecture.md`, `docs/06_Tech_Stack.md`, `docs/10_Roadmap_Milestones.md`, `docs/13_Agent_Change_Log.md`.
- Flags: none (documentation and strategy update).

### 2026-06-16 · Antigravity · Performance budgeting & automatic 2D fallback (T-PERF-200)
- **T-PERF-200:** implemented performance tier profiling and automatic degradation to the 2D path.
- Added `PerformanceManager` detecting low-end native environments (cores < 4) and mobile web browsers to route them to the low-end performance tier.
- Bypassed 3D asset downloads and scene manifest loading completely on low-end platforms, falling back directly to the 2D parallax/atmospheric rendering.
- Scaled particle count/density in `AtmosphericBackdrop` based on the performance tier multiplier (0.5 for mid-tier, 0.0 for low-tier).
- Files: `apps/client/lib/features/vignette/backdrop/performance_manager.dart`, `apps/client/lib/features/vignette/assets/asset_provider.dart`, `apps/client/lib/features/vignette/backdrop/atmospheric_backdrop.dart`, `apps/client/test/features/vignette/performance_manager_test.dart`.
- Flags: none new.

### 2026-06-16 · Antigravity · Native viewport polish & full-matrix support (T-CLIENT-200)
- **T-CLIENT-200:** implemented full-fidelity scene composition transformations on the native Thermion viewport, applying the resolved world matrix directly to assets.
- Added a custom `BoundedOrbitInputHandlerDelegate` mapping camera rig bounds (azimuth/polar angles, zoom limits, and zoom activation toggle) to the Filament viewer.
- Added check for the OS "reduce motion" preference (`MediaQuery.maybeOf(context)?.disableAnimations`) to disable orbit interactive controls dynamically.
- Files: `apps/client/lib/features/vignette/backdrop/three_d_viewport_io.dart`.
- Flags: none new. Real generation stays gated by Meshy/youth-safe restrictions.

### 2026-06-11 · Claude Code · Renderer consumes VignetteScene manifests (T-CLIENT-201 cont.)
- **T-CLIENT-201:** wired both viewports to consume `content/scenes/**`, generalizing the single-axis parallax composition into authored 3D placement. New pure-Dart `scene_models.dart` projects the `VignetteScene` schema and resolves each node's **world matrix** from its local TRS + anchor chain (cycle/missing-anchor safe). `AssetSceneLoader.loadScene` places every ready asset by that matrix and carries the **bounded camera rig**; `assetSceneProvider` prefers the scene and falls back to the parallax backdrop (then the 2D atmospheric layer) when no scene resolves — no regression for un-authored vignettes.
- **Web (unit-tested):** the GLB composer now bakes each asset's column-major world matrix into its wrapper `node.matrix` (was Z-only); `<model-viewer>` orbit/min/max + radius are derived from the rig (`phi = 90 − polar`), zoom stays disabled unless the scene enables it. **Native:** applies the world-matrix translation + frames the camera from the rig (per-asset rotation/scale + bounded-orbit clamp deferred to on-device T-CLIENT-200).
- Bundled `content/scenes/**` into the client (`make client-content-sync`, `pubspec.yaml`). Added `scene_models_test.dart` (TRS/anchor math + projection) and `scene_loader_test.dart`; updated `glb_scene_composer_test.dart` for the matrix API. Flutter not runnable in this env — relied on faithful additive edits + VM unit tests; CI runs analyze/test.
- Files: `apps/client/lib/features/vignette/{scene_models.dart,scene_provider.dart,assets/{asset_models.dart,asset_cache.dart,asset_provider.dart},backdrop/{glb_scene_composer.dart,three_d_viewport_web.dart,three_d_viewport_io.dart}}`, `apps/client/test/features/vignette/{scene_models_test.dart,scene_loader_test.dart,glb_scene_composer_test.dart}`, `apps/client/pubspec.yaml`, `Makefile`, `13`.
- Flags: none new. Real generation still gated — Meshy key + spend cap (#11), scene-level QA/safety/youth-safe (#7/#12). Not activated. Scene `asset_id`s remain authored in lockstep (the loader skips ids absent from the asset manifest, so today only ready assets render).

### 2026-06-11 · GitHub Copilot · Scene-composition schema + all 20 season-001 scenes (T-CONTENT-200)
- **T-CONTENT-200:** added `VignetteScene` schema (`vignette_scene.schema.json`) — one environment + placed props with transforms/anchors, scene-level lighting, and a **bounded camera rig** (look-at, default framing, azimuth/polar bounds, optional disabled zoom). Authored **all 20** season-001 vignettes as scenes (`content/scenes/season-001/scenes.manifest.json`), not 3.
- **`make validate-scenes`** + `--only scenes`: schema validation plus rules JSON Schema can't express (one scene per vignette, unique node ids, anchors must reference an existing node, camera rig internally consistent). Verified it **fails closed** on a tampered scene; added a validator unit test. Full `validate-content` and all 9 validator tests pass.
- Trait vectors unaffected by construction: `make replay` reads only `content/seasons` (scenes are presence-only and never fed to the trait engine).
- Files: `packages/content-schema/{vignette_scene.schema.json,index.js,README.md}`, `content/scenes/season-001/scenes.manifest.json`, `tools/content-validator/{bin/validate.js,test/validate.test.js,README.md}`, `Makefile`, `13`.
- Flags: none directly (additive content + validator). Real generation still gated — Meshy key + spend cap (#11), scene-level QA/safety/youth-safe (#7/#12). Not activated. Scene `asset_id`s are authored in lockstep and not cross-checked (matches the backdrop convention).

### 2026-06-11 · GitHub Copilot · Native orbit (T-CLIENT-200) + reconcile/enqueue entrypoint
- **T-CLIENT-200:** the native Thermion viewport is now explorable — wraps the scene in `ThermionListenerWidget` with `DelegateInputHandler.fixedOrbit`. Orbit is an enhancement that **falls back to a static render** if the handler can't be created, so it can't break the existing path. Compiles (`dart analyze`); on-device feel + bounding (clamp azimuth/polar, disable zoom) remain to validate on hardware.
- **Reconcile/enqueue entrypoint (T-ML-052):** `reconcile_main.py` + `make dev-asset-reconcile` load the Season manifests, diff desired-vs-ready, and publish missing/failed jobs through the `AssetSubmissionService` spend-cap chokepoint. `--list-only` (no DB/NATS) and `--dry-run` modes. ruff + mypy clean; `--list-only` validated on season-001.
- Files: `apps/client/lib/features/vignette/backdrop/three_d_viewport_io.dart`, `services/ml-py/app/services/asset_gen/reconcile_main.py`, `Makefile`.
- Flags: real generation still gated — Meshy key + spend cap (#11), scene-level QA/safety/youth-safe (#7/#12). Not activated.

### 2026-06-11 · GitHub Copilot · Web composed scenes (T-CLIENT-201) + gated Meshy
- **T-CLIENT-201:** added a pure-Dart GLB **scene composer** (`glb_scene_composer.dart`) that merges a vignette's layer GLBs into one composed scene (each placed by parallax Z) and wired it into the web viewport, so web renders the **full** scene — not a single object. Bails safely to the first asset for GLBs it can't merge losslessly (Draco/meshopt/textures/multi-buffer). VM unit-tested (4 tests).
- **Meshy (T-ML-200) wired as gated/not-activated:** `make dev-asset-worker-meshy` refuses to start unless **both** `MESHY_API_KEY` and `ECHO_ASSET_GEN_PERIOD_CAP > 0` are set, so paid generation can never run uncapped.
- **T-CLIENT-200 deferred** (native orbit needs on-device validation; API pointer recorded).
- Files: `apps/client/lib/features/vignette/backdrop/{glb_scene_composer.dart,three_d_viewport_web.dart}`, `apps/client/test/features/vignette/glb_scene_composer_test.dart`, `Makefile`.
- Flags: Meshy remains gated (#11) — not activated.

### 2026-06-11 · GitHub Copilot · Game-first re-sequencing + this change log
- Re-sequenced so **the whole game is built and signed off before** monetization/accounts/sharing/B2B: added the authoritative *Build order — the game comes first* and the **Game-Complete** gate (`10`), the *Build priority* table (`03`), the build-order directive (`07`), and pulled the explorable-3D milestone (**M6**) into **Phase G**. Annotated M2/M3/M4 and `F-AUTH-001`/`F-MONEY-001` as deferred.
- Added this file (`13`) and made maintaining it a binding agent rule.
- Docs/files: `03`, `07`, `10`, `13`, `AGENTS.md`.
- Flags: none (planning/sequencing only; no escalation areas touched).

### 2026-06-11 · GitHub Copilot · Vision pivot → explorable 3D vignettes
- Founder-approved product change: vignettes become **explorable 3D scenes** (calm, bounded *Monument Valley*-style dioramas; **Thermion/Filament**, not Unity). Updated `01`, `03` (`F-CORE-007`), `04` (interaction model), `05` (scene composition + web parity), `06` (Thermion role), and added milestone **M6** to `07`/`10`.
- Flags: ⚠️ operational gates await human sign-off — paid generation budget for Meshy (#11); scene-level QA/safety/brand + youth-safe review (#7/#12).

### 2026-06-11 · GitHub Copilot · Local 3D dev: generation, serving, explorable web viewport
- Fixed why no 3D rendered locally: the **web viewport** now creates `<model-viewer>` directly (the `model_viewer_plus` embedding wasn't painting) and is **explorable** (bounded drag-to-look; reduce-motion → still).
- Added a manifest-driven **dev asset generator** (`apps/client/tool/gen_dev_assets.py` — distinct GLB per asset), a CORS **dev CDN** (`apps/client/tool/dev_asset_cdn.py`), and `make` targets `gen-dev-assets` / `dev-asset-cdn` / `client-3d` / `dev-3d`. The web debug store now prefers the CDN over the bundled placeholder.
- Files: `apps/client/lib/features/vignette/backdrop/*`, `.../assets/asset_file_store_stub.dart`, `Makefile`, `apps/client/README.md`, `.gitignore`.
- Flags: none (debug-gated client changes; production rendering unchanged with the flag off).

### 2026-06-11 · GitHub Copilot · asset-gen failure observability
- Surfaced the real provider failure reason in `AllAssetGenProvidersFailedError` and the routing warning (previously hidden in `extra=`) after the asset worker looped on TRELLIS failures.
- Files: `services/ml-py/app/services/asset_gen/errors.py`, `routing.py`.
- Flags: none.

---
