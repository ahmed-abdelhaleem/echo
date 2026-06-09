"""Portrait generation service (T-ML-020 / T-ML-030 / T-ML-031).

This module is the **public-facing API** the gRPC servicer talks to.
It is a thin facade over the parametric renderer
(:mod:`app.services.portrait_renderer`), which carries the actual M2
composition.

History:
- **T-ML-020 (M1)** — a stdlib-only 64x64 placeholder lived here. The
  test suite still asserts the public contract (same vector → same
  output; shape validation), but the *visuals* now come from the
  parametric renderer.
- **T-ML-030 (M2)** — Pillow-backed parametric composition. 1080x1080
  static PNG by default.
- **T-ML-031 (M2)** — animated WebP loop available via the ``animate``
  flag.

We keep ``portrait_gen`` as the import path the gRPC server uses so the
servicer doesn't need to change shape; new callers can import
``portrait_renderer`` directly if they want access to the renderer
internals (golden tests do this).
"""

from __future__ import annotations

from dataclasses import dataclass

from app.services import portrait_renderer

# Re-exported so the gRPC servicer (and any monitoring tooling) can stamp
# the renderer version on outbound bytes without reaching across modules.
RENDERER_VERSION_M1 = 1
RENDERER_VERSION = portrait_renderer.RENDERER_VERSION_M2


@dataclass(frozen=True, slots=True)
class PortraitAssets:
    """Output of the Portrait generator.

    ``png`` is the inline static image. ``animated_webp`` is the inline
    animated loop when the caller requested ``animate=True``; empty
    bytes otherwise. ``static_png_key`` / ``animated_webp_key`` are
    populated once T-CORE-030 (sharing endpoint) wires R2 persistence;
    empty for callers that only need inline bytes.
    """

    png: bytes
    static_png_key: str
    animated_webp_key: str
    renderer_version: int
    animated_webp: bytes = b""


def generate(
    *,
    big_five: tuple[float, ...],
    schwartz: tuple[float, ...],
    attachment: tuple[float, ...],
    seed: int = 0,
    animate: bool = False,
) -> PortraitAssets:
    """Render a deterministic Portrait from a trait vector.

    Args:
        big_five: 5-tuple of Big Five scores, each in ``[-1.0, 1.0]``.
        schwartz: 10-tuple of Schwartz scores, each in ``[-1.0, 1.0]``.
        attachment: 3-tuple of attachment proxies, each in ``[0.0, 1.0]``.
        seed: optional caller-supplied seed. When 0 (the default), the
            seed is derived from the trait vector itself, which keeps
            the function purely deterministic. Non-zero seeds are
            useful for tests that want to confirm seed sensitivity.
        animate: when True, additionally emit the 24-frame WebP loop
            (T-ML-031). The static PNG is always returned.

    Returns:
        A :class:`PortraitAssets` with inline PNG bytes and a renderer
        version. R2 keys are empty unless the caller persists the
        bytes via the sharing endpoint (T-CORE-030, M2).

    Raises:
        ValueError: if any dimension array has the wrong shape.
    """
    rendered = portrait_renderer.generate(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        seed=seed,
        animate=animate,
    )
    return PortraitAssets(
        png=rendered.png,
        static_png_key="",
        animated_webp_key="",
        renderer_version=rendered.renderer_version,
        animated_webp=rendered.animated_webp,
    )
