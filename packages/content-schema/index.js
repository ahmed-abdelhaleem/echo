// Echo content-schema — convenience exports for Node consumers.
//
// JSON Schemas are the source of truth. This file simply imports them so that
// consumers (notably tools/content-validator) can `import { seasonSchema, ... }`
// instead of repeating fs.readFileSync calls.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));

function load(name) {
  return JSON.parse(readFileSync(resolve(here, name), "utf-8"));
}

export const seasonSchema = load("season.schema.json");
export const actSchema = load("act.schema.json");
export const vignetteSchema = load("vignette.schema.json");
export const choiceSchema = load("choice.schema.json");
export const traitWeightSchema = load("trait_weight.schema.json");
export const reflectionTemplateSchema = load("reflection_template.schema.json");

export const allSchemas = [
  seasonSchema,
  actSchema,
  vignetteSchema,
  choiceSchema,
  traitWeightSchema,
  reflectionTemplateSchema,
];
