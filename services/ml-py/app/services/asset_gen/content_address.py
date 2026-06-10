"""Content-address computation for 3D asset generation inputs (T-ML-050).

The content-address is a stable, deterministic sha256 hash of the
canonical generation inputs. It is used as the deduplication key for
asset generation jobs and as a caching identity in R2.

**Cross-language invariant.** This implementation MUST produce
byte-identical hashes to the Node validator at
:file:`tools/content-validator/lib/content_address.js`. The Node
validator is what stamps the ``content_address`` field on manifests in
:file:`content/assets-3d/**`; the Python server uses the same hash as
the lookup key. Drift between the two would silently double-generate
every asset (cache misses on every reconcile pass) and break the
deduplication invariant that the whole architecture rests on.

The shared canonical form is:

* The hashed payload is ``{"kind": ..., "generation": {...}}`` — the
  ``kind`` is one level *outside* the generation block. The Node
  validator builds this shape; the Python implementation matches it.
* Every default field is explicit (``negative_prompt: ""``, ``references:
  []``, ``params: {}``). Omitting a default-valued field changes the
  hash and breaks cross-language identity, so this implementation always
  emits them.
* ``references`` are normalised: ``sha256`` is dropped when absent, and
  the list is sorted by ``uri + (sha256 or "")`` so author-side ordering
  does not change the hash.
* Canonical JSON: sorted object keys, no whitespace, ``ensure_ascii=False``
  to match the Node ``JSON.stringify`` of non-ASCII strings, and
  ``allow_nan=False`` so accidentally non-JSON floats raise rather than
  silently producing output the JS side cannot reproduce.

The ``KNOWN_FIXTURE_ADDRESS`` test in
:mod:`tests.test_asset_gen_routing` locks the algorithm against
drift with a hard-coded sha256 that matches the Node fixture vector at
:file:`tools/content-validator/test/content_address.test.js`.

>>> from app.services.asset_gen.types import GenerationInputs
>>> inputs = GenerationInputs(
...     kind="prop",
...     provider="meshy",
...     mode="text-to-3d",
...     prompt="A worn leather satchel",
...     pipeline_version=1,
... )
>>> addr = compute_content_address(inputs)
>>> addr.startswith("sha256:")
True
>>> len(addr) == len("sha256:") + 64  # 7 + 64 hex chars
True
>>> compute_content_address(inputs) == compute_content_address(inputs)
True
"""

from __future__ import annotations

import hashlib
import json
from typing import Any

from app.services.asset_gen.types import GenerationInputs, Reference


def _canonical_reference(ref: Reference) -> dict[str, str]:
    """Drop ``sha256`` when absent so the canonical JSON matches the
    JS algorithm (which builds the object conditionally)."""
    if ref.sha256:
        return {"uri": ref.uri, "sha256": ref.sha256}
    return {"uri": ref.uri}


def _canonical_dict(inputs: GenerationInputs) -> dict[str, Any]:
    """Return the canonical pre-hash structure for ``inputs``.

    Mirrors :func:`canonicalGenerationInputs` in
    ``tools/content-validator/lib/content_address.js`` field-for-field.
    Bumping any key here without bumping the JS side will silently make
    the server and validator disagree about asset identity.
    """
    refs = [_canonical_reference(r) for r in inputs.references]
    refs.sort(key=lambda r: r["uri"] + r.get("sha256", ""))
    return {
        "kind": inputs.kind,
        "generation": {
            "provider": inputs.provider,
            "mode": inputs.mode,
            "prompt": inputs.prompt,
            "negative_prompt": inputs.negative_prompt,
            "references": refs,
            "params": dict(inputs.params),
            "pipeline_version": inputs.pipeline_version,
            "format": inputs.format,
        },
    }


def compute_content_address(inputs: GenerationInputs) -> str:
    """Return the ``sha256:<hex>`` content-address for ``inputs``.

    The address is deterministic and cross-language: the same logical
    inputs produce the same string in this Python implementation and in
    :file:`tools/content-validator/lib/content_address.js`.
    """
    canonical = _canonical_dict(inputs)
    payload = json.dumps(
        canonical,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"
