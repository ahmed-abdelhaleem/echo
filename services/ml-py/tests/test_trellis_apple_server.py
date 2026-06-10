"""Unit coverage for the Apple Silicon TRELLIS HTTP adapter."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest

MODULE_PATH = Path(__file__).parents[2] / "trellis-py" / "apple_server.py"
SPEC = importlib.util.spec_from_file_location("echo_apple_trellis_server", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
apple_server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(apple_server)


class _FakeTensor:
    def __init__(self, values: list[list[float]] | list[list[int]]) -> None:
        self._values = values

    def cpu(self) -> _FakeTensor:
        return self

    def numpy(self) -> list[list[float]] | list[list[int]]:
        return self._values


class _FakePipeline:
    def __init__(self) -> None:
        self.kwargs: dict[str, Any] = {}

    def run(self, image: object, **kwargs: object) -> list[object]:
        self.kwargs = {"image": image, **kwargs}
        return [
            SimpleNamespace(
                vertices=_FakeTensor([[0.0, 0.0, 0.0]] * 4),
                faces=_FakeTensor([[0, 1, 2], [0, 2, 3]]),
            )
        ]


def test_bounded_int_rejects_bool_and_out_of_range() -> None:
    with pytest.raises(ValueError, match="must be an integer"):
        apple_server._bounded_int(True, "steps", minimum=1)
    with pytest.raises(ValueError, match="outside the supported range"):
        apple_server._bounded_int(0, "steps", minimum=1)


def test_reference_uri_requires_http(monkeypatch: pytest.MonkeyPatch) -> None:
    pil_module = ModuleType("PIL")
    pil_module.Image = SimpleNamespace()
    monkeypatch.setitem(sys.modules, "PIL", pil_module)

    with pytest.raises(ValueError, match="must use http"):
        apple_server._load_reference_image([{"uri": "file:///tmp/reference.png"}])


def test_generate_rejects_unloaded_1024_pipeline(monkeypatch: pytest.MonkeyPatch) -> None:
    runtime = apple_server.AppleTrellisRuntime()
    monkeypatch.setattr(apple_server, "_load_reference_image", lambda references: object())

    with pytest.raises(ValueError, match="pipeline_type 512 only"):
        runtime.generate(
            {
                "mode": "image-to-3d",
                "references": [{"uri": "https://example.test/reference.png"}],
                "params": {"pipeline_type": "1024"},
            }
        )


def test_generate_exports_glb_and_passes_sampler_params(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    runtime = apple_server.AppleTrellisRuntime()
    pipeline = _FakePipeline()
    monkeypatch.setattr(runtime, "_load_pipeline", lambda: pipeline)
    monkeypatch.setattr(apple_server, "_load_reference_image", lambda references: "image")

    trimesh_module = ModuleType("trimesh")
    trimesh_module.Trimesh = lambda **kwargs: SimpleNamespace(
        export=lambda **export_kwargs: b"glTF-test"
    )
    monkeypatch.setitem(sys.modules, "trimesh", trimesh_module)

    result = runtime.generate(
        {
            "mode": "image-to-3d",
            "references": [{"uri": "https://example.test/reference.png"}],
            "params": {"seed": 7, "steps": 2, "target_polycount": 100},
        }
    )

    assert result == b"glTF-test"
    assert pipeline.kwargs["seed"] == 7
    assert pipeline.kwargs["pipeline_type"] == "512"
    assert pipeline.kwargs["sparse_structure_sampler_params"] == {"steps": 2}
