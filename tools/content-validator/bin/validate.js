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
} from "@echo/content-schema";

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
  } else if (a === "-h" || a === "--help") {
    flags.help = true;
  } else {
    console.error(`unknown argument: ${a}`);
    process.exit(2);
  }
}

if (flags.help) {
  console.log("usage: validate.js [--root <repo_root>] [--self-check]");
  process.exit(0);
}

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
for await (const entry of glob(seasonPattern)) {
  seasonFiles.push(entry);
}

if (seasonFiles.length === 0) {
  console.error(`no season.json files found under ${seasonsDir}`);
  process.exit(2);
}

const templatesDir = join(repoRoot, "content", "reflection-templates");
const templatePattern = join(templatesDir, "*.template.json");

const templateFiles = [];
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

if (failed > 0) {
  console.error(
    `\n${failed} content file(s) failed validation (across ${seasonFiles.length} season(s) and ${templateFiles.length} template(s)).`,
  );
  process.exit(1);
}
console.log(
  `\n${seasonFiles.length} season(s) and ${templateFiles.length} reflection template(s) validated.`,
);
