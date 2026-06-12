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

- **T-CLIENT-200 — on-device native polish:** native (Thermion) now applies the full per-asset world-matrix (TRS + anchor chain) composed onto the unit-cube normalization, matching the web path's `node.matrix` placement; reduce-motion suppresses free-look like the web still framing does. **Remaining for device:** bounded orbit clamping (azimuth/polar limits, disable-zoom) per the rig's `bounds` — the Thermion `InputHandler` clamp API surface is validated on hardware before we wire it. Real-generation activation stays **blocked on human approval**: Meshy key + spend cap (#11) and the scene-level QA/safety/youth-safe review (#7/#12).

---

## Change log

### 2026-06-11 · Claude Code · Native full-matrix placement + reduce-motion gate (T-CLIENT-200)
- **T-CLIENT-200 (native, partial):** the Thermion viewport now composes each asset's resolved scene world matrix onto the unit-cube normalization (`Matrix4..copyFromArray(placementMatrix).multiplied(unitTransform)`), generalizing the former translation-only placement to full TRS + anchor chain — matches what the web GLB composer bakes into `node.matrix`. Parallax fallback unchanged (its `placementMatrix` is translation-only).
- **Reduce-motion** on native: `MediaQuery.disableAnimations` skips the `ThermionListenerWidget`, rendering at the rig's default framing with no free-look — mirrors the web viewport's still path (F-CORE-007).
- **Deferred to on-device validation:** bounded-orbit clamp (azimuth/polar limits, disable-zoom) per the rig's `bounds`. The Thermion `DelegateInputHandler` clamp API surface is verified on hardware before wiring. All graceful-degradation paths (orbit handler unavailable, Thermion init failed → `ModelViewer` fallback on mobile, viewer null → empty) are preserved.
- Verified: `dart format` clean and format-stable under the repo's language version (3.6). Runtime correctness — orbit feel, camera framing on real scenes, full-TRS visual parity with web — requires the device run.
- Files: `apps/client/lib/features/vignette/backdrop/three_d_viewport_io.dart`, `13`.
- Flags: native rendering changes are runtime-unverifiable in this env; explicit hand-off to on-device validation. Real generation still gated — Meshy key + spend cap (#11), scene-level QA/safety/youth-safe (#7/#12).

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

