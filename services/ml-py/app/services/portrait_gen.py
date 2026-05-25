"""Portrait generation stub (T-ML-020).

This is the *M1 placeholder*. It returns a tiny deterministic PNG that
is keyed by the trait vector:

  - same trait vector  -> byte-identical PNG
  - different vector   -> structurally different PNG

The real parametric renderer (Pillow/Cairo, animated WebP) lands at M2
(T-ML-030 / T-ML-031). The M1 stub exists so the rest of the vertical
slice has something to render — the client gets a real PNG it can
display, and the share-web flow can be exercised end-to-end on a
placeholder.

Implementation note
-------------------
We intentionally do **not** depend on Pillow/Cairo here. Adding either
as a top-level dependency would trip AGENTS.md §"adding a new top-level
dependency requires explicit justification", and we'd be adding it
twice (once for the stub, then ripping it out for the real M2
renderer). The stub builds a minimal valid PNG by hand from
``struct`` + ``zlib`` — both stdlib — at the cost of one ``IDAT``
chunk and ~600 bytes per image.
"""

from __future__ import annotations

import hashlib
import struct
import zlib
from dataclasses import dataclass

# Bumped when the renderer changes in a way that would produce a
# different PNG for the same trait vector. core-go records this
# alongside the bytes so we can invalidate caches deterministically.
RENDERER_VERSION_M1 = 1

# Image is intentionally tiny: 64x64 keeps the placeholder visually
# distinguishable while staying under 1 KB per image. The M2 renderer
# will produce 1080x1080 at real quality.
_IMAGE_SIDE = 64

# Number of horizontal "trait bands" stacked top-to-bottom. 18 bands
# == one per trait dimension, ordered the same way as
# trait_scoring.BIG_FIVE_ORDER + SCHWARTZ_ORDER + ATTACHMENT_ORDER.
# Each band is _IMAGE_SIDE // 18 ~= 3 px tall plus a few remainder
# rows at the bottom.
_NUM_BANDS = 18


@dataclass(frozen=True, slots=True)
class PortraitAssets:
    """Output of the Portrait generator.

    ``png`` is inline image bytes; M2 will additionally populate the R2
    keys (``static_png_key`` / ``animated_webp_key``) once the renderer
    writes to object storage.
    """

    png: bytes
    static_png_key: str
    animated_webp_key: str
    renderer_version: int


def generate(
    *,
    big_five: tuple[float, ...],
    schwartz: tuple[float, ...],
    attachment: tuple[float, ...],
    seed: int = 0,
) -> PortraitAssets:
    """Render a deterministic placeholder Portrait from a trait vector.

    Args:
        big_five: 5-tuple of Big Five scores, each in ``[-1.0, 1.0]``.
        schwartz: 10-tuple of Schwartz scores, each in ``[-1.0, 1.0]``.
        attachment: 3-tuple of attachment proxies, each in ``[0.0, 1.0]``.
        seed: optional caller-supplied seed. When 0 (the default), the
            seed is derived from the trait vector itself, which keeps
            the function purely deterministic. Non-zero seeds are
            useful for tests that want to confirm seed sensitivity.

    Returns:
        A ``PortraitAssets`` with inline PNG bytes and a renderer
        version. R2 keys are empty strings in M1; M2 populates them.

    Raises:
        ValueError: if any dimension array has the wrong shape.
    """
    if len(big_five) != 5:
        raise ValueError(f"big_five must have 5 values, got {len(big_five)}")
    if len(schwartz) != 10:
        raise ValueError(f"schwartz must have 10 values, got {len(schwartz)}")
    if len(attachment) != 3:
        raise ValueError(f"attachment must have 3 values, got {len(attachment)}")

    vector = tuple(big_five) + tuple(schwartz) + tuple(attachment)
    # len(vector) == _NUM_BANDS by construction; guarded by the three
    # shape checks above.

    rgb_bands = _vector_to_rgb_bands(vector, seed=seed)
    png_bytes = _render_png(rgb_bands)

    return PortraitAssets(
        png=png_bytes,
        static_png_key="",
        animated_webp_key="",
        renderer_version=RENDERER_VERSION_M1,
    )


# ---------------------------------------------------------------------------
# Mapping trait values -> deterministic colors
# ---------------------------------------------------------------------------


def _vector_to_rgb_bands(
    vector: tuple[float, ...],
    *,
    seed: int,
) -> list[tuple[int, int, int]]:
    """Map each trait dimension to a deterministic (R, G, B) triple.

    Algorithm: hash (seed, dimension_index, value) with SHA-256 and
    take the first three bytes. The seed mixes in so two different
    seeds produce two different palettes for the same vector; the
    dimension index mixes in so two adjacent dimensions don't
    collapse onto identical colors when their values are close.
    """
    out: list[tuple[int, int, int]] = []
    for i, value in enumerate(vector):
        # Quantize so floats that round-trip through float32 still
        # produce the same color (gRPC double -> Go float64 -> Python
        # float is fine, but we want deterministic-across-platforms).
        quantized = round(value * 10_000)
        material = f"{seed}|{i}|{quantized}".encode()
        digest = hashlib.sha256(material).digest()
        out.append((digest[0], digest[1], digest[2]))
    return out


# ---------------------------------------------------------------------------
# Minimal pure-stdlib PNG writer
# ---------------------------------------------------------------------------


def _render_png(rgb_bands: list[tuple[int, int, int]]) -> bytes:
    """Render an _IMAGE_SIDE x _IMAGE_SIDE PNG split into horizontal bands.

    Each band is a solid block of the band's color. The last band
    swallows any remainder rows so the image is exactly _IMAGE_SIDE
    rows tall regardless of _NUM_BANDS.
    """
    band_height = _IMAGE_SIDE // _NUM_BANDS
    remainder = _IMAGE_SIDE - band_height * _NUM_BANDS

    rows: list[bytes] = []
    for band_idx, (r, g, b) in enumerate(rgb_bands):
        h = band_height + (remainder if band_idx == _NUM_BANDS - 1 else 0)
        # PNG scanline = filter byte (0 = None) + RGB triples.
        scanline = b"\x00" + bytes((r, g, b)) * _IMAGE_SIDE
        rows.extend([scanline] * h)

    raw = b"".join(rows)
    compressed = zlib.compress(raw, level=9)

    png_signature = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(
        ">IIBBBBB",
        _IMAGE_SIDE,  # width
        _IMAGE_SIDE,  # height
        8,  # bit depth
        2,  # color type 2 = RGB
        0,  # compression
        0,  # filter
        0,  # interlace
    )

    return (
        png_signature
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", compressed)
        + _png_chunk(b"IEND", b"")
    )


def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    """Serialize a single PNG chunk with the required CRC32 trailer."""
    length = struct.pack(">I", len(data))
    crc = struct.pack(">I", zlib.crc32(chunk_type + data) & 0xFFFFFFFF)
    return length + chunk_type + data + crc
