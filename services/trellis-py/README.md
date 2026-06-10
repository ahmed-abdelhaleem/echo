# `services/trellis-py`

Internal HTTP wrapper around
[Microsoft TRELLIS](https://github.com/microsoft/TRELLIS). The HTTP boundary
isolates model-specific runtimes from Echo's Python 3.12 `ml-py` service and
keeps model loading outside the request-serving process.

## Apple Silicon

TRELLIS can run locally on Apple Silicon without an NVIDIA GPU. The upstream
Microsoft repositories remain CUDA-oriented, so use an Apple Silicon port such
as:

- [`shivampkumar/trellis-mac`](https://github.com/shivampkumar/trellis-mac):
  PyTorch MPS/Metal port of TRELLIS.2.
- [`pedronaugusto/trellis2-apple`](https://github.com/pedronaugusto/trellis2-apple):
  MLX backend with a compatible `api_server.py`.

The MLX API accepts image-to-3D requests. Run it from its checkout:

```bash
python api_server.py --host 127.0.0.1 --port 8082
```

Configure Echo:

```bash
ECHO_ASSET_GEN_ENABLED=true
ECHO_ASSET_GEN_PRIMARY=trellis
ECHO_ASSET_GEN_FALLBACKS=
TRELLIS_BASE_URL=http://127.0.0.1:8082
TRELLIS_API_STYLE=trellis2-apple
```

Use an asset manifest with `mode: "image-to-3d"` and exactly one reference
image. The Apple Silicon API currently does not provide text-to-3D.

The repository also includes an adapter for the patched PyTorch MPS port from
`shivampkumar/trellis-mac`. After running that port's `setup.sh`, start:

```bash
export TRELLIS_MAC_ROOT=/path/to/trellis-mac
"$TRELLIS_MAC_ROOT/.venv/bin/python" \
  /path/to/echo/services/trellis-py/apple_server.py
```

This adapter uses Echo's native `POST /v1/generate` contract, so configure
`TRELLIS_API_STYLE=echo`. It defaults to the 512 pipeline and geometry-only GLB
export to keep memory and processing time reasonable on a 24 GB Mac. Mesh
simplification toward `target_polycount` is best-effort; highly detailed meshes
may remain above the requested target.

## CUDA Runtime

For the original Microsoft TRELLIS checkout on a CUDA host:

```bash
. ./setup.sh --new-env --basic --xformers --flash-attn \
  --diffoctreerast --spconv --mipgaussian --kaolin --nvdiffrast

conda activate trellis
PYTHONPATH="$PWD" python /path/to/echo/services/trellis-py/server.py
```

The first request downloads and loads the configured model. Override defaults
with `TRELLIS_TEXT_MODEL`, `TRELLIS_IMAGE_MODEL`, `TRELLIS_BIND`, and
`TRELLIS_PORT`.

Configure Echo:

```bash
ECHO_ASSET_GEN_ENABLED=true
ECHO_ASSET_GEN_PRIMARY=trellis
ECHO_ASSET_GEN_FALLBACKS=
TRELLIS_BASE_URL=http://gpu-host.internal:8090
TRELLIS_API_STYLE=echo
```

`POST /v1/generate` returns `model/gltf-binary`. `GET /healthz` is a lightweight
process health check; model loading remains lazy.
