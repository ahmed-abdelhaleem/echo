"""Parametric Portrait renderer (T-ML-030, T-ML-031).

The M2 renderer replaces the M1 18-band placeholder with a real
parametric composition. Output is deterministic from
``(TraitVector, seed)``: the same input always produces byte-identical
PNG bytes and an identical WebP frame sequence.

Composition (layered, polar coordinates):

1. **Background** — radial gradient from an inner color (derived from
   OCEAN-O / Openness) to an outer color (derived from OCEAN-C /
   Conscientiousness). High openness → warm inner; high conscientiousness
   → cooler edge. Sets emotional tone.
2. **Concentric rings** — count = ``3 + round(|neuroticism| * 4)``,
   thickness from OCEAN-A / Agreeableness. Conveys "how layered" the
   personality feels.
3. **Central polygon** — N sides = ``5 + round(extraversion_clipped * 5)``,
   rotation derived from Schwartz openness-to-change. Filled with a
   palette derived from the trait vector via the same hash as M1.
4. **Attachment ribbons** — three concentric arcs near the centre, each
   weighted by an attachment dimension (secure, anxious, avoidant). The
   secure dimension is the brightest; anxious dimension drives ribbon
   wobble.
5. **Texture overlay** — light speckle, density from the absolute mean
   of all trait values, seeded by ``seed``.

Animation (T-ML-031):
- ``ANIMATION_FRAMES = 24`` at 12 fps → 2-second loop.
- Only the central polygon and attachment ribbons rotate; the background
  + concentric rings stay fixed so the loop reads as "gentle pulse".
- Encoded as a single animated WebP at ``method=6, quality=80`` to hit
  the <800 KB / 1080x1080 budget.

Both the static and animated outputs run through the same
``_compose_frame(vector, seed, phase)`` function; ``phase`` is 0 for the
static render and sweeps across ``[0, 1)`` for the animation.

Determinism guarantees:
- Identical ``(trait_vector, seed)`` → byte-identical PNG.
- Identical ``(trait_vector, seed)`` → byte-identical WebP (Pillow's
  WebP encoder is deterministic when given identical frames + params).
- Trait values are quantized to ``1/10000`` before hashing so float32
  round-tripping doesn't shift colors across platforms.

The 10 golden tests in ``tests/test_portrait_renderer_goldens.py`` lock
the rendered bytes for ten representative trait vectors. Any change
that alters output (palette, geometry, animation params) must bump
``RENDERER_VERSION_M2`` and refresh the goldens — that triggers a
human-review-required PR per AGENTS.md §10 (trait engine boundary).
"""

from __future__ import annotations

import hashlib
import io
import math
from dataclasses import dataclass

from PIL import Image, ImageDraw, ImageFilter

# Bumped when the renderer changes in a way that would produce a
# different image for the same trait vector. M1 stub == 1; M2
# parametric renderer == 2.
RENDERER_VERSION_M2 = 2

# Default static render resolution. Public surface (docs/03 §"Portrait")
# calls for 1080x1080 for the Story/share surfaces; the renderer is
# parameterized on ``size`` so tests can render at smaller resolutions.
STATIC_SIZE = 1080

# Animation parameters. 24 frames at 12 fps == 2 second loop. Pillow's
# WebP encoder emits one frame per element of ``append_images``; we keep
# the count small enough that the encoded artifact fits comfortably under
# the 800 KB budget at 1080x1080.
ANIMATION_FRAMES = 24
ANIMATION_FPS = 12
ANIMATION_DURATION_MS = round(1000 / ANIMATION_FPS)

# WebP encoder settings. ``method=6`` is the slowest / highest-quality
# setting; ``quality=80`` is comfortable for organic gradients without
# visible banding. These are knobs we may tune at M2.5 when we have real
# bandwidth telemetry.
_WEBP_METHOD = 6
_WEBP_QUALITY = 80


@dataclass(frozen=True, slots=True)
class PortraitRender:
    """Rendered Portrait assets from the parametric renderer.

    ``png`` is always populated; ``animated_webp`` is populated only
    when ``generate(...)``'s ``animate`` argument was true.
    """

    png: bytes
    animated_webp: bytes
    renderer_version: int


def generate(
    *,
    big_five: tuple[float, ...],
    schwartz: tuple[float, ...],
    attachment: tuple[float, ...],
    seed: int = 0,
    animate: bool = False,
    size: int = STATIC_SIZE,
) -> PortraitRender:
    """Render a deterministic parametric Portrait from a trait vector.

    Args:
        big_five: 5-tuple of Big Five scores in ``[-1.0, 1.0]``.
        schwartz: 10-tuple of Schwartz scores in ``[-1.0, 1.0]``.
        attachment: 3-tuple of attachment proxies in ``[0.0, 1.0]``.
        seed: optional caller-supplied seed. When 0, the seed is derived
            from the trait vector itself, keeping the function purely
            deterministic. Non-zero seeds shift the speckle/texture
            layer only.
        animate: when True, additionally render the 24-frame WebP loop.
        size: render resolution (square). Defaults to 1080 (production);
            tests pass smaller values to keep golden artifacts small.

    Returns:
        A ``PortraitRender`` with PNG bytes (always) and animated WebP
        bytes (when ``animate=True``).

    Raises:
        ValueError: if any dimension array has the wrong shape or
            ``size`` is non-positive.
    """
    if len(big_five) != 5:
        raise ValueError(f"big_five must have 5 values, got {len(big_five)}")
    if len(schwartz) != 10:
        raise ValueError(f"schwartz must have 10 values, got {len(schwartz)}")
    if len(attachment) != 3:
        raise ValueError(f"attachment must have 3 values, got {len(attachment)}")
    if size <= 0:
        raise ValueError(f"size must be positive, got {size}")

    vector = tuple(big_five) + tuple(schwartz) + tuple(attachment)

    # Render the static (non-animated) layers once; per-frame work then
    # only needs to redraw the rotating polygon + ribbons. Cuts a
    # full-size 24-frame animation from ~40s to ~3s on commodity CI.
    palette = _derive_palette(vector, seed=seed)
    base = _render_static_layers(vector, palette=palette, seed=seed, size=size)
    static_frame = _apply_animated_layers(base.copy(), vector, palette=palette, phase=0.0)
    png_bytes = _encode_png(static_frame)

    if animate:
        frames = [
            _apply_animated_layers(
                base.copy(),
                vector,
                palette=palette,
                phase=i / ANIMATION_FRAMES,
            )
            for i in range(ANIMATION_FRAMES)
        ]
        webp_bytes = _encode_animated_webp(frames)
    else:
        webp_bytes = b""

    return PortraitRender(
        png=png_bytes,
        animated_webp=webp_bytes,
        renderer_version=RENDERER_VERSION_M2,
    )


# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------


def _render_static_layers(
    vector: tuple[float, ...],
    *,
    palette: list[tuple[int, int, int]],
    seed: int,
    size: int,
) -> Image.Image:
    """Render the non-animated layers (background + rings + texture).

    These are identical across every frame in the animation, so we
    compute them once and ``.copy()`` per frame.
    """
    img = _render_background(size, palette)
    _draw_concentric_rings(img, vector, palette)
    _apply_texture_overlay(img, vector, seed=seed)
    return img


def _apply_animated_layers(
    img: Image.Image,
    vector: tuple[float, ...],
    *,
    palette: list[tuple[int, int, int]],
    phase: float,
) -> Image.Image:
    """Apply the per-frame (rotating) layers on top of a static base.

    ``phase`` ∈ [0, 1) drives polygon rotation + ribbon orbit; phase=0
    is the canonical "static" frame and must match the PNG output.
    """
    _draw_central_polygon(img, vector, palette, phase=phase)
    _draw_attachment_ribbons(img, vector, palette, phase=phase)
    return img


def _derive_palette(
    vector: tuple[float, ...],
    *,
    seed: int,
) -> list[tuple[int, int, int]]:
    """Hash (seed, dim_index, quantized_value) → 18 RGB triples.

    Identical to the M1 stub's palette derivation. Keeping the same
    color mapping means trait-vector-to-color identity is stable across
    renderer versions; only the *composition* changes between M1 and M2.
    """
    out: list[tuple[int, int, int]] = []
    for i, value in enumerate(vector):
        quantized = round(value * 10_000)
        material = f"{seed}|{i}|{quantized}".encode()
        digest = hashlib.sha256(material).digest()
        out.append((digest[0], digest[1], digest[2]))
    return out


# ---------------------------------------------------------------------------
# Layer renderers
# ---------------------------------------------------------------------------


def _render_background(size: int, palette: list[tuple[int, int, int]]) -> Image.Image:
    """Radial gradient between OCEAN-O (inner) and OCEAN-C (outer)."""
    inner = palette[0]  # OCEAN-O / Openness
    outer = palette[1]  # OCEAN-C / Conscientiousness
    img = Image.new("RGB", (size, size), color=outer)
    pixels = img.load()
    assert pixels is not None  # narrowing for mypy
    cx, cy = size / 2, size / 2
    max_r = math.hypot(cx, cy)
    # Coarse step: write every 4th pixel and rely on the post-pass blur
    # to smooth the gradient. This keeps render time bounded — full
    # per-pixel iteration on 1080x1080 takes ~3s in pure Python.
    step = 4
    for y in range(0, size, step):
        for x in range(0, size, step):
            d = math.hypot(x - cx, y - cy) / max_r
            t = min(1.0, d)
            r = round(inner[0] * (1 - t) + outer[0] * t)
            g = round(inner[1] * (1 - t) + outer[1] * t)
            b = round(inner[2] * (1 - t) + outer[2] * t)
            for dy in range(step):
                for dx in range(step):
                    px, py = x + dx, y + dy
                    if px < size and py < size:
                        pixels[px, py] = (r, g, b)
    # Box blur to hide the 4-pixel stepping artifact.
    return img.filter(ImageFilter.GaussianBlur(radius=size // 200))


def _draw_concentric_rings(
    img: Image.Image,
    vector: tuple[float, ...],
    palette: list[tuple[int, int, int]],
) -> None:
    """3-7 concentric rings, count from |Neuroticism|, color from palette."""
    size = img.size[0]
    cx, cy = size / 2, size / 2
    neuroticism = vector[3]  # OCEAN-N
    agreeableness = vector[2]  # OCEAN-A
    ring_count = 3 + round(abs(neuroticism) * 4)
    # Ring thickness scales gently with agreeableness; clamp so very low
    # agreeableness still produces visible rings.
    thickness = max(2, round(size / 240 * (1 + agreeableness)))

    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    max_r = size * 0.45
    min_r = size * 0.18
    for i in range(ring_count):
        t = i / max(1, ring_count - 1)
        radius = min_r + (max_r - min_r) * t
        color = palette[5 + i % 10]  # Schwartz palette slice
        bbox = (cx - radius, cy - radius, cx + radius, cy + radius)
        od.ellipse(bbox, outline=(*color, 110), width=thickness)
    img.alpha_composite(overlay) if img.mode == "RGBA" else img.paste(overlay, (0, 0), overlay)


def _draw_central_polygon(
    img: Image.Image,
    vector: tuple[float, ...],
    palette: list[tuple[int, int, int]],
    *,
    phase: float,
) -> None:
    """N-sided polygon, N from Extraversion, rotation from Schwartz O2C."""
    size = img.size[0]
    cx, cy = size / 2, size / 2
    extraversion = vector[4]  # OCEAN-E
    schwartz_o2c = vector[5 + 4]  # SCH-stimulation as a stand-in
    sides = max(3, 5 + round(abs(extraversion) * 5))
    base_angle = schwartz_o2c * math.pi  # static portion
    angle = base_angle + phase * (math.tau / 2)  # half-revolution loop
    radius = size * 0.16

    points = []
    for i in range(sides):
        theta = angle + (math.tau * i / sides)
        points.append((cx + radius * math.cos(theta), cy + radius * math.sin(theta)))

    fill = palette[10]
    outline = palette[11]
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.polygon(points, fill=(*fill, 220), outline=(*outline, 255))
    img.alpha_composite(overlay) if img.mode == "RGBA" else img.paste(overlay, (0, 0), overlay)


def _draw_attachment_ribbons(
    img: Image.Image,
    vector: tuple[float, ...],
    palette: list[tuple[int, int, int]],
    *,
    phase: float,
) -> None:
    """3 arcs near the centre, weighted by the attachment dimensions."""
    size = img.size[0]
    cx, cy = size / 2, size / 2
    secure, anxious, avoidant = vector[15], vector[16], vector[17]
    # Anxious dim drives ribbon wobble; phase animates rotation.
    wobble = anxious * (size * 0.005)
    base_angle = phase * math.tau

    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for i, (strength, color) in enumerate(
        [
            (secure, palette[15]),
            (anxious, palette[16]),
            (avoidant, palette[17]),
        ]
    ):
        if strength <= 0:
            continue
        r = size * 0.22 + i * size * 0.025 + wobble
        bbox = (cx - r, cy - r, cx + r, cy + r)
        # Arc length scales with the dimension's strength (capped at full
        # circle so a strength of 1.0 produces a full ring).
        span = min(360, round(strength * 360))
        start = round(math.degrees(base_angle))
        end = start + span
        width = max(2, round(size * 0.005))
        od.arc(bbox, start=start, end=end, fill=(*color, 230), width=width)
    img.alpha_composite(overlay) if img.mode == "RGBA" else img.paste(overlay, (0, 0), overlay)


def _apply_texture_overlay(
    img: Image.Image,
    vector: tuple[float, ...],
    *,
    seed: int,
) -> None:
    """Sparse speckle overlay, density from |trait mean|, seeded.

    The texture is *not* animated — same seed → same speckle pattern on
    every frame — so the loop reads as gentle without high-frequency
    flicker.
    """
    size = img.size[0]
    mean_abs = sum(abs(v) for v in vector) / len(vector)
    density = max(0.01, min(0.05, 0.005 + mean_abs * 0.04))
    count = int(size * size * density)

    # Deterministic PRNG seeded by (seed, vector hash) — we don't want
    # to pull in numpy just for this.
    quantized = tuple(round(v * 10_000) for v in vector)
    hash_seed = int.from_bytes(
        hashlib.sha256(f"{seed}|{quantized}".encode()).digest()[:8],
        "big",
    )
    state = hash_seed or 1  # avoid zero seed in LCG

    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for _ in range(count):
        # Tiny LCG — sufficient for randomness in a Portrait speckle.
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        x = (state >> 32) % size
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        y = (state >> 32) % size
        # Alternating light/dark speckles for texture.
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        light = (state >> 32) & 1
        color = (255, 255, 255, 35) if light else (0, 0, 0, 35)
        od.point((x, y), fill=color)
    img.alpha_composite(overlay) if img.mode == "RGBA" else img.paste(overlay, (0, 0), overlay)


# ---------------------------------------------------------------------------
# Encoders
# ---------------------------------------------------------------------------


def _encode_png(img: Image.Image) -> bytes:
    """Encode an Image to PNG bytes deterministically."""
    flat = img.convert("RGB")
    buf = io.BytesIO()
    flat.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def _encode_animated_webp(frames: list[Image.Image]) -> bytes:
    """Encode a frame list to an animated WebP loop.

    Pillow's WebP encoder uses ``append_images`` for additional frames.
    Loop is set to 0 (infinite). Method 6 is the slowest, highest-quality
    encoder mode.
    """
    if not frames:
        raise ValueError("frames must be non-empty")
    rgb_frames = [f.convert("RGB") for f in frames]
    buf = io.BytesIO()
    rgb_frames[0].save(
        buf,
        format="WEBP",
        save_all=True,
        append_images=rgb_frames[1:],
        duration=ANIMATION_DURATION_MS,
        loop=0,
        method=_WEBP_METHOD,
        quality=_WEBP_QUALITY,
        minimize_size=True,
    )
    return buf.getvalue()
