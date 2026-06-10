"""Object storage adapters for generated assets."""

from __future__ import annotations

import importlib
import os
from pathlib import Path, PurePosixPath
from typing import Any, Protocol


class AssetObjectStore(Protocol):
    def put(self, key: str, data: bytes, *, content_type: str) -> str: ...


class LocalAssetObjectStore:
    """Filesystem-backed object store for local development and tests."""

    def __init__(self, root: Path, *, base_uri: str = "") -> None:
        self._root = root.resolve()
        self._base_uri = base_uri.rstrip("/")

    def put(self, key: str, data: bytes, *, content_type: str) -> str:
        del content_type
        relative = _safe_key(key)
        destination = self._root.joinpath(*relative.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_suffix(f"{destination.suffix}.tmp")
        temporary.write_bytes(data)
        os.replace(temporary, destination)
        if self._base_uri:
            return f"{self._base_uri}/{relative.as_posix()}"
        return destination.as_uri()


class R2AssetObjectStore:
    """Cloudflare R2 adapter using its S3-compatible API."""

    def __init__(
        self,
        *,
        bucket: str,
        endpoint_url: str,
        access_key_id: str,
        secret_access_key: str,
        public_base_url: str = "",
        client: Any | None = None,
    ) -> None:
        if not all((bucket, endpoint_url, access_key_id, secret_access_key)):
            raise ValueError("R2 bucket, endpoint, access key, and secret are required")
        self._bucket = bucket
        self._public_base_url = public_base_url.rstrip("/")
        if client is None:
            boto3 = importlib.import_module("boto3")
            client = boto3.client(
                "s3",
                endpoint_url=endpoint_url,
                aws_access_key_id=access_key_id,
                aws_secret_access_key=secret_access_key,
                region_name="auto",
            )
        self._client = client

    def put(self, key: str, data: bytes, *, content_type: str) -> str:
        normalized = _safe_key(key).as_posix()
        self._client.put_object(
            Bucket=self._bucket,
            Key=normalized,
            Body=data,
            ContentType=content_type,
        )
        if self._public_base_url:
            return f"{self._public_base_url}/{normalized}"
        return f"r2://{self._bucket}/{normalized}"


def _safe_key(key: str) -> PurePosixPath:
    path = PurePosixPath(key)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError("object key must be a safe relative path")
    return path
