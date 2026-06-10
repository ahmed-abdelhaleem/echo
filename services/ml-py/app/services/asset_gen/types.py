"""Public types for the asset-gen provider abstraction (T-ML-050).

These types are the input and output contract between the
:class:`~app.services.asset_gen.base.AssetGenProvider` protocol and its
callers. They are intentionally decoupled from the gRPC proto types so
the provider layer is testable without a gRPC channel.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

# Mirrors AssetKind enum in asset_gen.proto.
AssetKind = Literal["prop", "environment", "character", "ambient"]

# Mirrors Provider enum in asset_gen.proto (only the two used in this PR).
ProviderID = Literal["meshy", "trellis"]

# Mirrors GenMode enum.
GenMode = Literal["text-to-3d", "image-to-3d"]

# Mirrors AssetFormat enum.
AssetFormat = Literal["glb", "gltf"]


@dataclass(frozen=True, slots=True)
class Reference:
    """A reference image (for image-to-3d mode).

    ``uri`` is required; ``sha256`` is an optional integrity hash that
    is included in the content-address when present so a changed
    reference image invalidates the address.
    """

    uri: str
    sha256: str = ""


@dataclass(frozen=True, slots=True)
class GenerationInputs:
    """All fields that feed into the content-address hash.

    Together with the asset ``kind``, these fields are *exactly* what
    ``compute_content_address`` hashes — kept in sync with
    ``asset_manifest.schema.json`` and the ``Generation`` message in
    ``asset_gen.proto``.

    Constraints:
    - ``prompt`` must be non-empty.
    - ``references`` is required when ``mode == 'image-to-3d'``; the
      provider implementations enforce this.
    - ``pipeline_version`` must be ≥ 1.
    """

    kind: AssetKind
    provider: ProviderID
    mode: GenMode
    prompt: str
    pipeline_version: int
    format: AssetFormat = "glb"
    negative_prompt: str = ""
    references: tuple[Reference, ...] = ()
    # Provider-tunable params. Keys are sorted before hashing so insertion
    # order does not change the content-address.
    params: dict[str, object] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if not self.prompt:
            raise ValueError("prompt must not be empty")
        if self.pipeline_version < 1:
            raise ValueError("pipeline_version must be >= 1")
        if self.mode == "image-to-3d" and not self.references:
            raise ValueError("references required for image-to-3d mode")


@dataclass(frozen=True, slots=True)
class AssetGenRequest:
    """A single asset generation request.

    ``inputs`` carries everything the provider needs and is what the
    content-address is computed from. ``asset_id`` is a stable
    human-readable identifier used only for logging.

    When ``dry_run`` is True the router computes the content-address but
    does not call any provider.
    """

    inputs: GenerationInputs
    asset_id: str = ""
    dry_run: bool = False


@dataclass(frozen=True, slots=True)
class AssetGenResult:
    """Result of a successful generation.

    ``glb_bytes`` is ``None`` on a dry-run.

    ``content_address`` always carries the ``sha256:<hex>`` identifier
    so callers can record it even on dry-runs.
    """

    content_address: str
    provider_used: str
    glb_bytes: bytes | None = None
    is_stub: bool = False
