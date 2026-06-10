"""Asset-gen provider abstraction (T-ML-050).

The background asset-generation pipeline talks to 3D asset providers
through the :class:`AssetGenProvider` protocol declared in
:mod:`.base`. Concrete implementations:

- :mod:`.trellis` — :class:`TrellisProvider`: HTTP client for the
  self-hosted Microsoft TRELLIS GPU service.
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

The T-ML-051 worker core remains dependency-injected. Production adapters for
NATS JetStream, Postgres, and R2 are installed through the ``asset-worker``
optional dependency extra.
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
    DEFAULT_TRELLIS_BASE_URL,
    KNOWN_PROVIDERS,
    build_provider,
    build_provider_from_env,
)
from app.services.asset_gen.meshy import MeshyProvider
from app.services.asset_gen.models import (
    AssetJob,
    AssetRecord,
    AssetSpec,
    AssetStatus,
    EnqueueResult,
)
from app.services.asset_gen.postprocess import (
    AssetPostProcessingError,
    AutomatedAssetQualityGate,
    GateResult,
    GlbInspection,
    GltfpackPostProcessor,
    ProcessedAsset,
    inspect_glb,
)
from app.services.asset_gen.queue import (
    AssetJobPublisher,
    AssetSubmissionService,
    InMemoryAssetJobQueue,
    NatsAssetJobPublisher,
    run_nats_worker,
)
from app.services.asset_gen.repository import (
    AssetRepository,
    InMemoryAssetRepository,
    PostgresAssetRepository,
)
from app.services.asset_gen.routing import RoutingAssetGenProvider, RoutingResult
from app.services.asset_gen.storage import (
    AssetObjectStore,
    LocalAssetObjectStore,
    R2AssetObjectStore,
)
from app.services.asset_gen.trellis import TrellisProvider
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
from app.services.asset_gen.worker import AssetGenerationWorker

__all__ = [
    "DEFAULT_FALLBACKS",
    "DEFAULT_PRIMARY",
    "DEFAULT_TRELLIS_BASE_URL",
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
    "AssetGenerationWorker",
    "AssetJob",
    "AssetJobPublisher",
    "AssetKind",
    "AssetObjectStore",
    "AssetPostProcessingError",
    "AssetRecord",
    "AssetRepository",
    "AssetSpec",
    "AssetStatus",
    "AssetSubmissionService",
    "AutomatedAssetQualityGate",
    "EnqueueResult",
    "GateResult",
    "GenMode",
    "GenerationInputs",
    "GlbInspection",
    "GltfpackPostProcessor",
    "InMemoryAssetJobQueue",
    "InMemoryAssetRepository",
    "LocalAssetObjectStore",
    "MeshyProvider",
    "NatsAssetJobPublisher",
    "PostgresAssetRepository",
    "ProcessedAsset",
    "ProviderID",
    "R2AssetObjectStore",
    "Reference",
    "RoutingAssetGenProvider",
    "RoutingResult",
    "TrellisProvider",
    "build_provider",
    "build_provider_from_env",
    "compute_content_address",
    "inspect_glb",
    "run_nats_worker",
]
