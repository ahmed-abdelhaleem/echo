// Unit tests for the deterministic 3D-asset content-address (T-CONTENT-004).

import { test } from "node:test";
import assert from "node:assert/strict";
import { contentAddress } from "../lib/content_address.js";

const fixture = {
  kind: "prop",
  generation: {
    provider: "meshy",
    mode: "text-to-3d",
    prompt: "a chipped enamel coffee mug, half full",
    params: { seed: 7, pbr: true, target_polycount: 12000 },
    pipeline_version: 1,
    format: "glb",
  },
};

const clone = (o) => JSON.parse(JSON.stringify(o));

test("content-address is deterministic", () => {
  assert.equal(contentAddress(fixture), contentAddress(clone(fixture)));
});

test("param key order does not change the address", () => {
  const reordered = clone(fixture);
  reordered.generation.params = { target_polycount: 12000, pbr: true, seed: 7 };
  assert.equal(contentAddress(reordered), contentAddress(fixture));
});

test("changing a generation input changes the address", () => {
  const changed = clone(fixture);
  changed.generation.prompt += " on a windowsill";
  assert.notEqual(contentAddress(changed), contentAddress(fixture));
});

test("metadata fields do not affect the address", () => {
  const withMeta = clone(fixture);
  withMeta.id = "whatever";
  withMeta.name = "X";
  withMeta.description = "notes";
  withMeta.license = "CC0";
  withMeta.status = "ready";
  withMeta.budget_tier = "premium";
  withMeta.vignette_ids = ["v-1"];
  assert.equal(contentAddress(withMeta), contentAddress(fixture));
});

test("known vector locks the algorithm", () => {
  assert.equal(
    contentAddress(fixture),
    "sha256:6b03ec452f43b2ffc920bb615cd1d76749f3f526a32060ba30d16f788016935c",
  );
});
