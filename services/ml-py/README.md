# `services/ml-py`

The Echo ML service. Per `docs/05_Technical_Architecture.md` this is a Python
process that owns trait scoring, Portrait generation, reflection generation,
the safety/tone classifiers, and the provider-facing side of background 3D
asset generation.

## Layout

```
services/ml-py/
├── app/
│   ├── main.py                  # FastAPI app: /healthz, /readyz
│   ├── grpc_server.py           # gRPC server (TraitScoringService)
│   ├── grpc_gen/                # protoc-generated stubs (committed; regenerate via `make proto`)
│   └── services/
│       ├── trait_scoring.py     # M1 (T-ML-010) — implemented
│       ├── portrait_gen.py      # M2 (T-ML-030)
│       ├── reflection_gen.py    # M2 (T-ML-040)
│       └── asset_gen/           # Meshy/TRELLIS provider routing
└── tests/
```

## Run

```bash
uv sync

# HTTP /healthz, /readyz
uv run uvicorn app.main:app --reload

# gRPC TraitScoringService (default :50051)
uv run python -m app.grpc_server

# Background 3D asset worker (requires the asset-worker extra + gltfpack)
uv sync --extra asset-worker
uv run python -m app.services.asset_gen.worker_main
```

The Go core service dials the gRPC server via `ML_GRPC_ADDR` (e.g.
`ML_GRPC_ADDR=127.0.0.1:50051`); when that env var is unset, trait
scoring is disabled and `POST /playthroughs/{id}/finalize` returns 503.

## TRELLIS

TRELLIS runs as a separate process so its model-specific environment stays
isolated from Echo's Python 3.12 service. Configure `TRELLIS_BASE_URL`,
`TRELLIS_API_STYLE`, and opt in with `ECHO_ASSET_GEN_ENABLED=true`. See
[`services/trellis-py/README.md`](../trellis-py/README.md).

The original Microsoft runtime is CUDA-oriented. Apple Silicon can run
TRELLIS.2 locally through community MPS/MLX ports, without an NVIDIA GPU.

## Asset Worker

T-ML-051 runs as a separate process from HTTP/gRPC. `SubmitAsset` writes an
idempotent metadata row and publishes a JetStream job; the worker generates
through the configured provider chain, optimizes with `gltfpack`, creates two
LOD files and a thumbnail, runs the automated structural gate, stores outputs,
and marks the row ready.

Local development uses `ECHO_ASSET_STORE_BACKEND=local`. Deployed workers use
the R2-compatible backend and the `R2_*` variables in `.env.example`.

The `asset-worker` extra adds three production-boundary dependencies:

- `nats-py`: the official asyncio JetStream client.
- `psycopg[binary]`: transactional generated-asset metadata in Postgres.
- `boto3`: Cloudflare R2's S3-compatible object API.

Mesh optimization is intentionally an external tool rather than another Python
runtime dependency. Install
[`gltfpack`](https://meshoptimizer.org/gltf/) and set `GLTFPACK_BIN` if it is
not on `PATH`.

The automated gate currently covers objective GLB, embedding, size, polygon,
LOD, and thumbnail checks. Its policy and the generated metadata thumbnail
require human review before merge under the repository's asset QA/brand-gate
rule.

## Verify

```bash
uv run pytest -q
uv run ruff check .
uv run ruff format --check .
uv run mypy app
```
