"""Asset-gen provider abstraction (T-ML-050).

The background asset-generation pipeline talks to 3D asset providers
through the :class:`AssetGenProvider` protocol declared in
:mod:`.base`. Concrete implementations:

- :mod:`.self_hosted` — :class:`SelfHostedProvider`: open-model fallback
  (TripoSR / InstantMesh). Returns a placeholder GLB in T-ML-050; the
  real gRPC call to the model server lands with T-ML-051.
- :mod:`.meshy`       — :class:`MeshyProvider`: Meshy primary. Validates
  the API key at construction; ``generate()`` raises in T-ML-050 so
  the router exercices the fallback path without real spend.
- :mod:`.routing`     — :class:`RoutingAssetGenProvider` chains a primary
  with an ordered list of fallbacks. T-ML-050's acceptance criterion
  ("forced failure on primary routes to fallback with no caller change")
  is implemented and tested here.
- :mod:`.content_address` — :func:`compute_content_address` hashes
  generation inputs to a stable ``sha256:<hex>`` identifier.
- :mod:`.factory`     — :func:`build_provider_from_env` returns the
  configured routing provider based on
  ``ECHO_ASSET_GEN_PRIMARY`` / ``ECHO_ASSET_GEN_FALLBACKS``.

This package ships **zero** new top-level dependencies. All hashing uses
stdlib :mod:`hashlib` / :mod:`json`. Real provider HTTP SDKs land with
T-ML-051 under a ``human-review-required`` label per AGENTS.md §11.
"""

from app.services.asset_gen.base import AssetGenProvider
from app.services.asset_gen.content_address import compute_content_address
from app.services.asset_gen.errors import (
    AllAssetGenProvidersFailedError,
    AssetGenConfigurationError,
    AssetGenError,
    AssetGenProviderError,
    AssetGenProviderHTTPError,
    AssetGenProviderTimeoutError,
)
from app.services.asset_gen.factory import (
    DEFAULT_FALLBACKS,
    DEFAULT_PRIMARY,
    KNOWN_PROVIDERS,
    build_provider,
    build_provider_from_env,
)
from app.services.asset_gen.meshy import MeshyProvider
from app.services.asset_gen.routing import RoutingAssetGenProvider, RoutingResult
from app.services.asset_gen.self_hosted import SelfHostedProvider
from app.services.asset_gen.types import (
    AssetFormat,
    AssetGenRequest,
    AssetGenResult,
    AssetKind,
    GenerationInputs,
    GenMode,
    ProviderID,
    Reference,
)

__all__ = [
    "DEFAULT_FALLBACKS",
    "DEFAULT_PRIMARY",
    "KNOWN_PROVIDERS",
    "AllAssetGenProvidersFailedError",
    "AssetFormat",
    "AssetGenConfigurationError",
    "AssetGenError",
    "AssetGenProvider",
    "AssetGenProviderError",
    "AssetGenProviderHTTPError",
    "AssetGenProviderTimeoutError",
    "AssetGenRequest",
    "AssetGenResult",
    "AssetKind",
    "GenMode",
    "GenerationInputs",
    "MeshyProvider",
    "ProviderID",
    "Reference",
    "RoutingAssetGenProvider",
    "RoutingResult",
    "SelfHostedProvider",
    "build_provider",
    "build_provider_from_env",
    "compute_content_address",
]
