"""Domain records for the T-ML-051 background asset worker."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any, cast

from app.services.asset_gen.content_address import compute_content_address
from app.services.asset_gen.types import (
    AssetFormat,
    AssetKind,
    GenerationInputs,
    GenMode,
    ProviderID,
    Reference,
)


class AssetStatus(StrEnum):
    DESIRED = "desired"
    QUEUED = "queued"
    GENERATING = "generating"
    POSTPROCESSING = "postprocessing"
    QA = "qa"
    READY = "ready"
    FAILED = "failed"


@dataclass(frozen=True, slots=True)
class AssetSpec:
    """All authored metadata and generation inputs for one desired asset."""

    asset_id: str
    inputs: GenerationInputs
    season_id: str = ""
    name: str = ""
    description: str = ""
    vignette_ids: tuple[str, ...] = ()
    license: str = "provider-terms"
    budget_tier: str = "standard"
    claimed_content_address: str = field(default="", compare=False)

    def __post_init__(self) -> None:
        if not self.asset_id:
            raise ValueError("asset_id must not be empty")
        if self.budget_tier not in {"standard", "premium"}:
            raise ValueError("budget_tier must be standard or premium")
        if not self.license:
            raise ValueError("license must not be empty")
        if self.claimed_content_address and self.claimed_content_address != self.content_address:
            raise ValueError("claimed content_address does not match generation inputs")

    @property
    def content_address(self) -> str:
        return compute_content_address(self.inputs)

    def to_dict(self) -> dict[str, object]:
        generation: dict[str, object] = {
            "provider": self.inputs.provider,
            "mode": self.inputs.mode,
            "prompt": self.inputs.prompt,
            "negative_prompt": self.inputs.negative_prompt,
            "references": [
                {"uri": ref.uri, "sha256": ref.sha256} if ref.sha256 else {"uri": ref.uri}
                for ref in self.inputs.references
            ],
            "params": self.inputs.params,
            "pipeline_version": self.inputs.pipeline_version,
            "format": self.inputs.format,
        }
        return {
            "id": self.asset_id,
            "season_id": self.season_id,
            "name": self.name,
            "description": self.description,
            "kind": self.inputs.kind,
            "vignette_ids": list(self.vignette_ids),
            "license": self.license,
            "budget_tier": self.budget_tier,
            "content_address": self.content_address,
            "generation": generation,
        }

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> AssetSpec:
        generation = value.get("generation")
        if not isinstance(generation, dict):
            raise ValueError("asset generation must be an object")
        references_raw = generation.get("references", [])
        if not isinstance(references_raw, list):
            raise ValueError("generation references must be a list")
        references = tuple(
            Reference(uri=str(ref["uri"]), sha256=str(ref.get("sha256", "")))
            for ref in references_raw
            if isinstance(ref, dict)
        )
        params = generation.get("params", {})
        if not isinstance(params, dict):
            raise ValueError("generation params must be an object")
        inputs = GenerationInputs(
            kind=cast("AssetKind", value["kind"]),
            provider=cast("ProviderID", generation["provider"]),
            mode=cast("GenMode", generation["mode"]),
            prompt=str(generation["prompt"]),
            negative_prompt=str(generation.get("negative_prompt", "")),
            references=references,
            params=dict(params),
            pipeline_version=int(generation["pipeline_version"]),
            format=cast("AssetFormat", generation.get("format", "glb")),
        )
        vignette_ids = value.get("vignette_ids", [])
        if not isinstance(vignette_ids, list):
            raise ValueError("vignette_ids must be a list")
        return cls(
            asset_id=str(value["id"]),
            season_id=str(value.get("season_id", "")),
            name=str(value.get("name", "")),
            description=str(value.get("description", "")),
            inputs=inputs,
            vignette_ids=tuple(str(item) for item in vignette_ids),
            license=str(value.get("license", "provider-terms")),
            budget_tier=str(value.get("budget_tier", "standard")),
            claimed_content_address=str(value.get("content_address", "")),
        )


@dataclass(frozen=True, slots=True)
class AssetJob:
    """Versioned JetStream payload for one generation attempt."""

    spec: AssetSpec
    schema_version: int = 1

    def to_bytes(self) -> bytes:
        return json.dumps(
            {
                "schema_version": self.schema_version,
                "spec": self.spec.to_dict(),
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    @classmethod
    def from_bytes(cls, payload: bytes) -> AssetJob:
        decoded = json.loads(payload)
        if not isinstance(decoded, dict) or decoded.get("schema_version") != 1:
            raise ValueError("unsupported asset job schema_version")
        spec = decoded.get("spec")
        if not isinstance(spec, dict):
            raise ValueError("asset job spec must be an object")
        return cls(spec=AssetSpec.from_dict(spec))


@dataclass(frozen=True, slots=True)
class AssetRecord:
    """Persisted lifecycle and output metadata for one content-address."""

    spec: AssetSpec
    status: AssetStatus
    provider_used: str = ""
    glb_uri: str = ""
    thumbnail_uri: str = ""
    lod_uris: tuple[str, ...] = ()
    polycount: int = 0
    size_bytes: int = 0
    error: str = ""
    attempt_count: int = 0
    created_at: datetime = field(default_factory=lambda: datetime.now(UTC))
    updated_at: datetime = field(default_factory=lambda: datetime.now(UTC))
    ready_at: datetime | None = None
    lease_expires_at: datetime | None = None

    @property
    def content_address(self) -> str:
        return self.spec.content_address


@dataclass(frozen=True, slots=True)
class EnqueueResult:
    record: AssetRecord
    deduplicated: bool
    should_publish: bool
