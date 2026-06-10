"""Content-address computation for 3D asset generation inputs (T-ML-050).

The content-address is a stable, deterministic sha256 hash of the
canonical generation inputs. It is used as the deduplication key for
asset generation jobs and as a caching identity in R2.

The canonical form is defined as:
  sha256(canonical_json(inputs))

where canonical_json produces the input dict with **sorted keys** and
no unnecessary whitespace — identical to what the JSON Schema validator
``tools/content-validator`` uses (``sort_keys=True, separators=(',', ':')``)
so Go, Python, and JavaScript all agree on the same hash.

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

from app.services.asset_gen.types import GenerationInputs


def _canonical_dict(inputs: GenerationInputs) -> dict[str, Any]:
    """Return a dict of the generation inputs that feeds into the hash.

    Only the fields that are part of the content-address are included —
    matching the ``asset_manifest.schema.json`` spec.  Fields marked
    *"Not part of the content-address"* in the schema (``description``,
    ``vignette_ids``, ``budget_tier``) are intentionally excluded.
    """
    d: dict[str, Any] = {
        "kind": inputs.kind,
        "provider": inputs.provider,
        "mode": inputs.mode,
        "prompt": inputs.prompt,
        "pipeline_version": inputs.pipeline_version,
        "format": inputs.format,
    }
    if inputs.negative_prompt:
        d["negative_prompt"] = inputs.negative_prompt
    if inputs.references:
        d["references"] = [
            {"uri": ref.uri, "sha256": ref.sha256} if ref.sha256 else {"uri": ref.uri}
            for ref in inputs.references
        ]
    if inputs.params:
        # Sort params by key so insertion order doesn't change the hash.
        d["params"] = dict(sorted(inputs.params.items()))
    return d


def compute_content_address(inputs: GenerationInputs) -> str:
    """Return the ``sha256:<hex>`` content-address for ``inputs``.

    The address is deterministic: the same ``GenerationInputs`` always
    produces the same string regardless of the Python process or machine.

    Choice of canonical serialisation: ``json.dumps(sort_keys=True,
    separators=(',', ':'))`` matches the existing JS implementation in
    ``tools/content-validator`` so cross-language content-addresses
    are bit-identical.
    """
    canonical = _canonical_dict(inputs)
    # sort_keys=True: redundant since _canonical_dict already inserts
    # in key-sorted order for the top level, but defensive for nested
    # objects (params could have nested maps in future).
    payload = json.dumps(canonical, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    return f"sha256:{digest}"
