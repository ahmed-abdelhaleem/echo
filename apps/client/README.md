# Echo client (Flutter)

Cross-platform Flutter client for Echo. Targets Android, iOS, web, Linux, macOS, Windows from one codebase.

## Status

**M0 — scaffold.** This directory contains:

- The routing, theming, and localisation rails.
- A trivial `HomeScreen` → `VignetteScreen` flow used to verify routing works.
- A `Dio`-based `ApiClient` aimed at `services/core-go`.
- Smoke tests covering the boot, route, and HTTP layers.

The vignette renderer, design-token theme, telemetry instrumentation, and offline cache all land in **M1** under `T-CLIENT-010..020` per `docs/07_AI_Agent_Implementation_Guide.md`.

## Setup

From this directory:

```bash
flutter pub get
flutter analyze
flutter test
```

Flutter version is pinned at `.tool-versions` and matched in `pubspec.yaml`'s `environment` block.

### Web target — one-time setup

`drift_flutter` (used by the local Drift cache in `lib/data/local/database.dart`) requires the sqlite3 wasm bundle and the dedicated drift worker under `web/` before the app can boot in a browser. From the repo root, run once per checkout:

```bash
make client-web-assets
```

This drops `web/sqlite3.wasm` and `web/drift_worker.js` next to `web/index.html`. The two artifacts are large (~1 MB) and version-tied to the locked `drift` / `sqlite3` versions; they are intentionally **not** committed and are gitignored.

### macOS desktop without Xcode.app

`make client` defaults to **Chrome** when only Command Line Tools are installed (no `xcodebuild`). For the native macOS app, install [Xcode](https://apps.apple.com/app/xcode/id497799835) from the App Store, then:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
PLATFORM=macos make client
```

Skip this step for non-web targets — `drift_flutter` falls back to a native `path_provider`-backed `NativeDatabase` automatically.

## Layout

```
lib/
├── main.dart                    # Entry point — keep thin.
├── app/
│   ├── app.dart                 # MaterialApp.router root.
│   ├── router.dart              # GoRouter config (Riverpod-managed).
│   └── theme.dart               # M0 placeholder theme.
├── features/
│   ├── home/
│   └── vignette/
└── services/
    └── api_client.dart          # Dio wrapper for core-go.
test/
├── widget_test.dart             # Boot smoke test.
├── router_test.dart             # Home <-> Vignette navigation.
└── services/
    └── api_client_test.dart     # ApiClient.healthz happy-path.
```

## 3D backdrops in dev

Vignette backdrops layer a generated 3D model (GLB) over the continuous 2D
atmosphere. In production the asset-gen worker generates each model with a real
provider and streams it from the asset CDN. Locally there is no GPU and no paid
provider (and the Apple TRELLIS server is image-to-3d only), so a manifest-driven
generator stands in: it reads `content/assets-3d/<season>/assets.manifest.json`
and writes a distinct, uncompressed GLB per asset at its content-addressed path.

One command does everything — generate per-asset GLBs, serve them with CORS, and
run the debug client pointed at them:

```bash
make dev-3d
```

Open vignette 1, 4, or 15 (the ones with a backdrop authored) and you'll see a
different shape/colour per asset (a box per environment, a sphere per prop,
hue seeded by the asset id). The debug flag also makes the `<model-viewer>`
viewport loud and visible: it logs the asset scene + model `load`/`error` to the
console (filter `echo3d`), draws a magenta border, paints an opaque background,
drops the legibility scrim, and auto-rotates the model.

The pieces, if you want to run them separately:

```bash
make gen-dev-assets   # synthesize one GLB per manifest asset into .echo-cdn/
make dev-asset-cdn    # CORS stand-in CDN on :8099 serving .echo-cdn/
make client-3d        # web client with ECHO_3D_DEBUG=true + ECHO_ASSET_CDN_URL
```

To preview *your own* model for every asset, drop a file at `.echo-cdn/override.glb`
(per-asset: `.echo-cdn/assets/sha256/<digest>/asset.glb`). None of this affects a
plain `make client` build — the debug flag is a compile-time const that defaults
off.

## Conventions

- File names: `lower_snake_case.dart`.
- Types: `PascalCase`.
- All new visual surfaces require a widget test. Portrait renderers also require golden tests (M1).
- Avoid `dynamic` outside generated code.

See [`AGENTS.md`](../../AGENTS.md) for the full convention set.
