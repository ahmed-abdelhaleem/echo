"""Configuration tests for the T-ML-051 worker process."""

from __future__ import annotations

from pathlib import Path

import pytest

from app.services.asset_gen.storage import LocalAssetObjectStore, R2AssetObjectStore
from app.services.asset_gen.worker_main import _build_object_store, build_worker_from_env


def test_worker_requires_explicit_size_budget() -> None:
    with pytest.raises(ValueError, match="ECHO_ASSET_MAX_BYTES"):
        build_worker_from_env({})


def test_worker_builds_with_local_storage(tmp_path: Path) -> None:
    worker = build_worker_from_env(
        {
            "DATABASE_URL": "postgres://localhost/echo",
            "ECHO_ASSET_MAX_BYTES": "1000000",
            "ECHO_ASSET_GEN_PRIMARY": "trellis",
            "ECHO_ASSET_GEN_FALLBACKS": "",
            "ECHO_ASSET_STORE_BACKEND": "local",
            "ECHO_ASSET_STORE_DIR": str(tmp_path),
        }
    )
    assert worker is not None


def test_object_store_rejects_unknown_backend() -> None:
    with pytest.raises(ValueError, match="local or r2"):
        _build_object_store({"ECHO_ASSET_STORE_BACKEND": "ftp"})


def test_object_store_builds_r2_with_required_settings(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sentinel = object()

    def fake_r2(**kwargs: str) -> object:
        assert kwargs["bucket"] == "echo-assets"
        return sentinel

    monkeypatch.setattr(
        "app.services.asset_gen.worker_main.R2AssetObjectStore",
        fake_r2,
    )
    result = _build_object_store(
        {
            "ECHO_ASSET_STORE_BACKEND": "r2",
            "R2_ASSET_BUCKET": "echo-assets",
            "R2_ENDPOINT_URL": "https://r2.example.test",
            "R2_ACCESS_KEY_ID": "test",
            "R2_SECRET_ACCESS_KEY": "test",
        }
    )
    assert result is sentinel


def test_storage_classes_remain_importable() -> None:
    assert LocalAssetObjectStore is not None
    assert R2AssetObjectStore is not None
