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

## Conventions

- File names: `lower_snake_case.dart`.
- Types: `PascalCase`.
- All new visual surfaces require a widget test. Portrait renderers also require golden tests (M1).
- Avoid `dynamic` outside generated code.

See [`AGENTS.md`](../../AGENTS.md) for the full convention set.
