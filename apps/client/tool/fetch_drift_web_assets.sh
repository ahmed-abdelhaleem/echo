#!/usr/bin/env bash
# Fetch version-pinned Drift web assets into web/. Run once per checkout
# (or after bumping drift / sqlite3 in pubspec.lock).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/web"

# Keep in sync with pubspec.lock (drift / sqlite3).
DRIFT_VERSION="${DRIFT_VERSION:-2.28.2}"
SQLITE3_VERSION="${SQLITE3_VERSION:-2.9.4}"

mkdir -p "$WEB"

echo "→ downloading drift_worker.js (drift ${DRIFT_VERSION})"
curl -fsSL \
  -o "$WEB/drift_worker.js" \
  "https://github.com/simolus3/drift/releases/download/drift-${DRIFT_VERSION}/drift_worker.js"

echo "→ downloading sqlite3.wasm (sqlite3 ${SQLITE3_VERSION})"
curl -fsSL \
  -o "$WEB/sqlite3.wasm" \
  "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_VERSION}/sqlite3.wasm"

echo "✓ web assets ready under apps/client/web/"
