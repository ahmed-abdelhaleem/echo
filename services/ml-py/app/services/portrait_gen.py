"""Portrait generation service stub.

Real implementation lands at M2 (T-ML-030). See
``packages/proto/portrait_gen.proto``.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class PortraitAssets:
    """R2 object keys for the rendered Portrait assets."""

    static_png_key: str
    animated_webp_key: str


def generate(playthrough_id: str, seed: int | None = None) -> PortraitAssets:
    """Stub. Real generation uses Pillow/Cairo per docs/05.

    Args:
        playthrough_id: stable ID of the playthrough whose vector to render.
        seed: optional explicit seed; defaults to a hash of the trait vector.

    Raises:
        NotImplementedError: always, in M0.
    """
    del playthrough_id, seed
    msg = "portrait generation not implemented in M0; see T-ML-030"
    raise NotImplementedError(msg)
