#!/usr/bin/env node
// Echo content validator.
//
// Walks content/ from the repo root and validates every season.json against
// packages/content-schema/. Per docs/07_AI_Agent_Implementation_Guide.md
// T-CONTENT-001 acceptance criterion: "validator passes on a sample Season."
//
// Usage:
//   node bin/validate.js [--root <repo_root>] [--self-check]
//
// Exit codes:
//   0  - all content valid
//   1  - one or more validation failures
//   2  - misuse (missing arg, bad path)

import { readFileSync, statSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { glob } from "node:fs/promises";
import Ajv from "ajv";

import {
  seasonSchema,
  actSchema,
  vignetteSchema,
  choiceSchema,
  traitWeightSchema,
  reflectionTemplateSchema,
  assetManifestSchema,
  vignetteBackdropSchema,
  vignetteSceneSchema,
} from "@echo/content-schema";

import { contentAddress } from "../lib/content_address.js";

// ---------------------------------------------------------------------------
// CLI arg parsing
// ---------------------------------------------------------------------------

const args = process.argv.slice(2);
const flags = {};
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--root") {
    flags.root = args[++i];
  } else if (a === "--self-check") {
    flags.selfCheck = true;
  } else if (a === "--only") {
    flags.only = args[++i];
  } else if (a === "--") {
    // pnpm forwards a literal `--` separator; ignore it.
    continue;
  } else if (a === "-h" || a === "--help") {
    flags.help = true;
  } else {
    console.error(`unknown argument: ${a}`);
    process.exit(2);
  }
}

if (flags.help) {
  console.log(
    "usage: validate.js [--root <repo_root>] [--self-check] [--only seasons|templates|assets|backdrops|scenes]",
  );
  process.exit(0);
}

const ONLY_KINDS = new Set(["seasons", "templates", "assets", "backdrops", "scenes"]);
if (flags.only && !ONLY_KINDS.has(flags.only)) {
  console.error(`--only must be one of: ${[...ONLY_KINDS].join(", ")}`);
  process.exit(2);
}
const run = {
  seasons: !flags.only || flags.only === "seasons",
  templates: !flags.only || flags.only === "templates",
  assets: !flags.only || flags.only === "assets",
  backdrops: !flags.only || flags.only === "backdrops",
  scenes: !flags.only || flags.only === "scenes",
};

// ---------------------------------------------------------------------------
// Find repo root (walk up until we find content/ + packages/content-schema/)
// ---------------------------------------------------------------------------

function findRepoRoot(startDir) {
  let cur = resolve(startDir);
  for (let i = 0; i < 20; i++) {
    if (
      tryStat(join(cur, "content")) &&
      tryStat(join(cur, "packages", "content-schema"))
    ) {
      return cur;
    }
    const parent = dirname(cur);
    if (parent === cur) break;
    cur = parent;
  }
  return null;
}

function tryStat(p) {
  try {
    return statSync(p);
  } catch {
    return null;
  }
}

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = flags.root ? resolve(flags.root) : findRepoRoot(here);
if (!repoRoot) {
  console.error("could not locate repo root from", here);
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Set up Ajv with all schemas
// ---------------------------------------------------------------------------

const ajv = new Ajv({
  allErrors: true,
  strict: false,
});

// Add all referenced schemas first; the Season schema $refs them by $id.
ajv.addSchema(actSchema);
ajv.addSchema(vignetteSchema);
ajv.addSchema(choiceSchema);
ajv.addSchema(traitWeightSchema);
const validateSeason = ajv.compile(seasonSchema);
const validateReflectionTemplate = ajv.compile(reflectionTemplateSchema);
const validateAssetManifest = ajv.compile(assetManifestSchema);
const validateVignetteBackdrop = ajv.compile(vignetteBackdropSchema);
const validateVignetteScene = ajv.compile(vignetteSceneSchema);

if (flags.selfCheck) {
  console.log("✓ content-validator self-check: all schemas compiled.");
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Find every season.json under content/seasons/
// ---------------------------------------------------------------------------

const seasonsDir = join(repoRoot, "content", "seasons");
const seasonPattern = join(seasonsDir, "*", "season.json");

const seasonFiles = [];
if (run.seasons) {
  for await (const entry of glob(seasonPattern)) {
    seasonFiles.push(entry);
  }

  if (seasonFiles.length === 0) {
    console.error(`no season.json files found under ${seasonsDir}`);
    process.exit(2);
  }
}

const templatesDir = join(repoRoot, "content", "reflection-templates");
const templatePattern = join(templatesDir, "*.template.json");

const templateFiles = [];
if (run.templates) {
  for await (const entry of glob(templatePattern)) {
    templateFiles.push(entry);
  }

  // Reflection templates are required by T-ML-040 (≥50 templates). We do
  // NOT short-circuit on an empty directory the way we do for seasons —
  // missing template content is a hard fail because the M2 reflection
  // pipeline depends on it.
  if (templateFiles.length === 0) {
    console.error(
      `no *.template.json files found under ${templatesDir} (T-ML-040 requires ≥50 templates)`,
    );
    process.exit(2);
  }
}

// ---------------------------------------------------------------------------
// Validate each
// ---------------------------------------------------------------------------

let failed = 0;

for (const file of seasonFiles) {
  const rel = file.slice(repoRoot.length + 1);
  let raw;
  try {
    raw = readFileSync(file, "utf-8");
  } catch (err) {
    console.error(`✗ ${rel}: ${err.message}`);
    failed++;
    continue;
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch (err) {
    console.error(`✗ ${rel}: invalid JSON: ${err.message}`);
    failed++;
    continue;
  }
  const ok = validateSeason(data);
  if (!ok) {
    console.error(`✗ ${rel}: schema validation failed:`);
    for (const e of validateSeason.errors ?? []) {
      const p = e.instancePath || "(root)";
      console.error(`    ${p} ${e.message}`);
    }
    failed++;
    continue;
  }
  console.log(`✓ ${rel}`);
}

for (const file of templateFiles) {
  const rel = file.slice(repoRoot.length + 1);
  let raw;
  try {
    raw = readFileSync(file, "utf-8");
  } catch (err) {
    console.error(`✗ ${rel}: ${err.message}`);
    failed++;
    continue;
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch (err) {
    console.error(`✗ ${rel}: invalid JSON: ${err.message}`);
    failed++;
    continue;
  }
  const ok = validateReflectionTemplate(data);
  if (!ok) {
    console.error(`✗ ${rel}: schema validation failed:`);
    for (const e of validateReflectionTemplate.errors ?? []) {
      const p = e.instancePath || "(root)";
      console.error(`    ${p} ${e.message}`);
    }
    failed++;
    continue;
  }

  // id must match basename (filename is the canonical key).
  const baseId = rel
    .split("/")
    .pop()
    .replace(/\.template\.json$/, "");
  if (data.id !== baseId) {
    console.error(
      `✗ ${rel}: id "${data.id}" does not match filename "${baseId}"`,
    );
    failed++;
    continue;
  }

  // min_sentences <= max_sentences.
  if (data.constraints.min_sentences > data.constraints.max_sentences) {
    console.error(
      `✗ ${rel}: constraints.min_sentences (${data.constraints.min_sentences}) > max_sentences (${data.constraints.max_sentences})`,
    );
    failed++;
    continue;
  }

  console.log(`✓ ${rel}`);
}

// ---------------------------------------------------------------------------
// Validate 3D asset manifests under content/assets-3d/ (T-CONTENT-004)
// ---------------------------------------------------------------------------

const assetsDir = join(repoRoot, "content", "assets-3d");
const assetPattern = join(assetsDir, "*", "*.manifest.json");

const assetFiles = [];
if (run.assets) {
  for await (const entry of glob(assetPattern)) {
    assetFiles.push(entry);
  }
}

for (const file of assetFiles) {
  const rel = file.slice(repoRoot.length + 1);
  let data;
  try {
    data = JSON.parse(readFileSync(file, "utf-8"));
  } catch (err) {
    console.error(`✗ ${rel}: invalid JSON: ${err.message}`);
    failed++;
    continue;
  }
  if (!validateAssetManifest(data)) {
    console.error(`✗ ${rel}: schema validation failed:`);
    for (const e of validateAssetManifest.errors ?? []) {
      console.error(`    ${e.instancePath || "(root)"} ${e.message}`);
    }
    failed++;
    continue;
  }

  // Rules JSON Schema can't express cleanly: unique ids, image-to-3d needs a
  // reference, and the content_address must match the generation inputs.
  let assetError = null;
  const seenIds = new Set();
  for (const asset of data.assets) {
    if (seenIds.has(asset.id)) {
      assetError = `duplicate asset id "${asset.id}"`;
      break;
    }
    seenIds.add(asset.id);

    if (asset.generation.mode === "image-to-3d" && !asset.generation.references?.length) {
      assetError = `asset "${asset.id}": mode 'image-to-3d' requires at least one reference`;
      break;
    }

    const expected = contentAddress(asset);
    if (asset.content_address !== expected) {
      assetError = `asset "${asset.id}": content_address ${asset.content_address} does not match generation inputs (${expected})`;
      break;
    }
  }
  if (assetError) {
    console.error(`✗ ${rel}: ${assetError}`);
    failed++;
    continue;
  }

  console.log(`✓ ${rel}`);
}

// ---------------------------------------------------------------------------
// Validate vignette backdrops under content/backdrops/ (T-CLIENT-041)
// ---------------------------------------------------------------------------

const backdropsDir = join(repoRoot, "content", "backdrops");
const backdropPattern = join(backdropsDir, "*", "*.manifest.json");

const backdropFiles = [];
if (run.backdrops) {
  for await (const entry of glob(backdropPattern)) {
    backdropFiles.push(entry);
  }
}

for (const file of backdropFiles) {
  const rel = file.slice(repoRoot.length + 1);
  let data;
  try {
    data = JSON.parse(readFileSync(file, "utf-8"));
  } catch (err) {
    console.error(`✗ ${rel}: invalid JSON: ${err.message}`);
    failed++;
    continue;
  }
  if (!validateVignetteBackdrop(data)) {
    console.error(`✗ ${rel}: schema validation failed:`);
    for (const e of validateVignetteBackdrop.errors ?? []) {
      console.error(`    ${e.instancePath || "(root)"} ${e.message}`);
    }
    failed++;
    continue;
  }

  // Rules JSON Schema can't express cleanly: at most one backdrop per vignette,
  // and unique layer ids within a backdrop.
  let bderr = null;
  const seenVignettes = new Set();
  for (const b of data.backdrops) {
    if (seenVignettes.has(b.vignette_id)) {
      bderr = `duplicate backdrop for vignette "${b.vignette_id}"`;
      break;
    }
    seenVignettes.add(b.vignette_id);

    const seenLayerIds = new Set();
    for (const layer of b.layers) {
      if (seenLayerIds.has(layer.id)) {
        bderr = `backdrop "${b.vignette_id}": duplicate layer id "${layer.id}"`;
        break;
      }
      seenLayerIds.add(layer.id);
    }
    if (bderr) break;
  }
  if (bderr) {
    console.error(`✗ ${rel}: ${bderr}`);
    failed++;
    continue;
  }

  console.log(`✓ ${rel}`);
}

// ---------------------------------------------------------------------------
// Validate explorable vignette scenes under content/scenes/ (T-CONTENT-200)
// ---------------------------------------------------------------------------

const scenesDir = join(repoRoot, "content", "scenes");
const scenePattern = join(scenesDir, "*", "*.manifest.json");

const sceneFiles = [];
if (run.scenes) {
  for await (const entry of glob(scenePattern)) {
    sceneFiles.push(entry);
  }
}

for (const file of sceneFiles) {
  const rel = file.slice(repoRoot.length + 1);
  let data;
  try {
    data = JSON.parse(readFileSync(file, "utf-8"));
  } catch (err) {
    console.error(`✗ ${rel}: invalid JSON: ${err.message}`);
    failed++;
    continue;
  }
  if (!validateVignetteScene(data)) {
    console.error(`✗ ${rel}: schema validation failed:`);
    for (const e of validateVignetteScene.errors ?? []) {
      console.error(`    ${e.instancePath || "(root)"} ${e.message}`);
    }
    failed++;
    continue;
  }

  // Rules JSON Schema can't express cleanly: at most one scene per vignette,
  // node ids unique within a scene, anchors must reference an existing node
  // (and not themselves), and the camera rig must be internally consistent
  // (default framing within bounds, sane min<=max, sane zoom range). A scene
  // that violates any of these fails closed.
  let scerr = null;
  const seenVignettes = new Set();
  for (const s of data.scenes) {
    if (seenVignettes.has(s.vignette_id)) {
      scerr = `duplicate scene for vignette "${s.vignette_id}"`;
      break;
    }
    seenVignettes.add(s.vignette_id);

    const nodes = [s.environment, ...(s.props ?? [])];
    const nodeIds = new Set();
    for (const n of nodes) {
      if (nodeIds.has(n.id)) {
        scerr = `scene "${s.vignette_id}": duplicate node id "${n.id}"`;
        break;
      }
      nodeIds.add(n.id);
    }
    if (scerr) break;

    for (const n of nodes) {
      if (n.anchor === undefined) continue;
      if (n.anchor === n.id) {
        scerr = `scene "${s.vignette_id}": node "${n.id}" anchors to itself`;
        break;
      }
      if (!nodeIds.has(n.anchor)) {
        scerr = `scene "${s.vignette_id}": node "${n.id}" anchor "${n.anchor}" is not a node in this scene`;
        break;
      }
    }
    if (scerr) break;

    const cam = s.camera;
    const az = cam.bounds.azimuth_deg;
    const po = cam.bounds.polar_deg;
    if (az.min > az.max) {
      scerr = `scene "${s.vignette_id}": camera.bounds.azimuth_deg.min (${az.min}) > max (${az.max})`;
      break;
    }
    if (po.min > po.max) {
      scerr = `scene "${s.vignette_id}": camera.bounds.polar_deg.min (${po.min}) > max (${po.max})`;
      break;
    }
    const df = cam.default_framing;
    if (df.azimuth_deg < az.min || df.azimuth_deg > az.max) {
      scerr = `scene "${s.vignette_id}": default_framing.azimuth_deg (${df.azimuth_deg}) is outside bounds [${az.min}, ${az.max}]`;
      break;
    }
    if (df.polar_deg < po.min || df.polar_deg > po.max) {
      scerr = `scene "${s.vignette_id}": default_framing.polar_deg (${df.polar_deg}) is outside bounds [${po.min}, ${po.max}]`;
      break;
    }
    const zoom = cam.bounds.zoom;
    if (zoom?.enabled) {
      const { min_distance, max_distance } = zoom;
      if (min_distance === undefined || max_distance === undefined) {
        scerr = `scene "${s.vignette_id}": camera.bounds.zoom is enabled but min_distance/max_distance are not both set`;
        break;
      }
      if (min_distance > max_distance) {
        scerr = `scene "${s.vignette_id}": camera.bounds.zoom.min_distance (${min_distance}) > max_distance (${max_distance})`;
        break;
      }
      if (cam.distance < min_distance || cam.distance > max_distance) {
        scerr = `scene "${s.vignette_id}": camera.distance (${cam.distance}) is outside zoom range [${min_distance}, ${max_distance}]`;
        break;
      }
    }
  }
  if (scerr) {
    console.error(`✗ ${rel}: ${scerr}`);
    failed++;
    continue;
  }

  console.log(`✓ ${rel}`);
}

if (failed > 0) {
  console.error(
    `\n${failed} content file(s) failed validation (across ${seasonFiles.length} season(s), ${templateFiles.length} template(s), ${assetFiles.length} asset manifest(s), ${backdropFiles.length} backdrop manifest(s), and ${sceneFiles.length} scene manifest(s)).`,
  );
  process.exit(1);
}
if (run.seasons || run.templates) {
  console.log(
    `\n${seasonFiles.length} season(s) and ${templateFiles.length} reflection template(s) validated.`,
  );
}
if (run.assets) {
  console.log(`${assetFiles.length} asset manifest(s) validated.`);
}
if (run.backdrops) {
  console.log(`${backdropFiles.length} backdrop manifest(s) validated.`);
}
if (run.scenes) {
  console.log(`${sceneFiles.length} scene manifest(s) validated.`);
}
