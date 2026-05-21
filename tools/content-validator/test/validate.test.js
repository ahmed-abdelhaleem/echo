// Smoke test for tools/content-validator.
//
// Runs the validator binary against the repo's content/ directory and asserts
// it exits 0. This is what `make node-test` verifies in CI.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const validator = resolve(here, "..", "bin", "validate.js");

test("validator passes self-check", () => {
  const out = execFileSync("node", [validator, "--self-check"], {
    encoding: "utf-8",
  });
  assert.match(out, /self-check/);
});

test("validator passes against repo content/", () => {
  // Cwd-independent: validator finds repo root by walking up from its own location.
  const out = execFileSync("node", [validator], {
    encoding: "utf-8",
  });
  assert.match(out, /season\(s\) validated/);
});
