// Deterministic content-address for 3D assets.
//
// An asset's identity is a stable hash of exactly its generation inputs (the
// asset `kind` plus the normalized `generation` block). Identical inputs always
// produce the same address, which is what makes background generation
// idempotent, cacheable, and reproducible across Seasons. Metadata fields
// (id/name/description/license/budget_tier/status/vignette_ids) are deliberately
// NOT part of the address.
//
// Keep this in sync with packages/content-schema/asset_manifest.schema.json and
// packages/proto/asset_gen.proto (the Generation message).

import { createHash } from "node:crypto";

// Canonical JSON: object keys sorted recursively, no insignificant whitespace.
// This makes the hash independent of key order in the source file.
export function canonicalize(value) {
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalize).join(",") + "]";
  }
  if (value && typeof value === "object") {
    const keys = Object.keys(value).sort();
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + canonicalize(value[k])).join(",") + "}";
  }
  return JSON.stringify(value);
}

// The exact, normalized inputs that define an asset's identity.
export function canonicalGenerationInputs(asset) {
  const g = asset.generation ?? {};
  const references = (g.references ?? [])
    .map((r) => (r.sha256 ? { uri: r.uri, sha256: r.sha256 } : { uri: r.uri }))
    .sort((a, b) => (a.uri + (a.sha256 ?? "")).localeCompare(b.uri + (b.sha256 ?? "")));
  return {
    kind: asset.kind,
    generation: {
      provider: g.provider,
      mode: g.mode,
      prompt: g.prompt,
      negative_prompt: g.negative_prompt ?? "",
      references,
      params: g.params ?? {},
      pipeline_version: g.pipeline_version,
      format: g.format,
    },
  };
}

export function contentAddress(asset) {
  const blob = canonicalize(canonicalGenerationInputs(asset));
  return "sha256:" + createHash("sha256").update(blob, "utf-8").digest("hex");
}
