"""Tests for the continuous reconciler / scheduler (T-ML-052).

Locks the acceptance criteria:
- N desired, M ready -> exactly N-M enqueued.
- budget cap never exceeded; overflow deferred and picked up next run.
- a second run with no changes enqueues nothing (idempotent).
- pre-warming across seasons under one shared budget, de-duplicated by
  content-address.
Plus: FAILED assets are re-enqueued, dry-run touches nothing, and the
real season-001 manifest loads + validates its stamped content-addresses.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from app.services.asset_gen import (
    AssetReconciler,
    AssetSpec,
    AssetSubmissionService,
    GenerationInputs,
    InMemoryAssetJobQueue,
    InMemoryAssetRepository,
    load_manifest_specs,
    reconcile_specs_in_order,
)

_REPO_ROOT = Path(__file__).resolve().parents[3]


def _spec(prompt: str, *, asset_id: str | None = None, season_id: str = "season-001") -> AssetSpec:
    return AssetSpec(
        asset_id=asset_id or prompt.replace(" ", "-"),
        season_id=season_id,
        inputs=GenerationInputs(
            kind="prop",
            provider="trellis",
            mode="text-to-3d",
            prompt=prompt,
            pipeline_version=1,
        ),
    )


def _build() -> tuple[AssetReconciler, InMemoryAssetRepository, InMemoryAssetJobQueue]:
    repo = InMemoryAssetRepository()
    queue = InMemoryAssetJobQueue()
    submission = AssetSubmissionService(repository=repo, publisher=queue)
    return AssetReconciler(submission=submission), repo, queue


def _mark_ready(repo: InMemoryAssetRepository, spec: AssetSpec) -> None:
    repo.enqueue(spec)
    repo.mark_ready(
        spec.content_address,
        provider_used="trellis",
        glb_uri="memory://x.glb",
        thumbnail_uri="",
        lod_uris=(),
        polycount=100,
        size_bytes=2048,
    )


# ---------------------------------------------------------------------------
# N desired, M ready -> N-M enqueued
# ---------------------------------------------------------------------------


def test_enqueues_exactly_the_missing_assets() -> None:
    reconciler, repo, queue = _build()
    specs = [_spec(f"asset {i}") for i in range(5)]
    # Two are already READY.
    _mark_ready(repo, specs[0])
    _mark_ready(repo, specs[3])

    outcome = reconciler.reconcile(specs)

    assert outcome.desired == 5
    assert len(outcome.enqueued) == 3  # N - M = 5 - 2
    assert set(outcome.already_ready) == {specs[0].content_address, specs[3].content_address}
    assert len(queue) == 3
    # The enqueued addresses are exactly the three not-ready specs.
    assert set(outcome.enqueued) == {
        specs[1].content_address,
        specs[2].content_address,
        specs[4].content_address,
    }


def test_all_missing_enqueues_all() -> None:
    reconciler, _repo, queue = _build()
    specs = [_spec(f"asset {i}") for i in range(4)]
    outcome = reconciler.reconcile(specs)
    assert len(outcome.enqueued) == 4
    assert outcome.already_ready == ()
    assert len(queue) == 4


# ---------------------------------------------------------------------------
# Budget cap
# ---------------------------------------------------------------------------


def test_budget_cap_is_never_exceeded() -> None:
    reconciler, _repo, queue = _build()
    specs = [_spec(f"asset {i}") for i in range(5)]

    outcome = reconciler.reconcile(specs, budget_cap=2)

    assert len(outcome.enqueued) == 2
    assert len(outcome.deferred) == 3
    assert outcome.budget_remaining == 0
    assert len(queue) == 2


def test_budget_cap_progresses_across_runs() -> None:
    reconciler, _repo, queue = _build()
    specs = [_spec(f"asset {i}") for i in range(5)]

    first = reconciler.reconcile(specs, budget_cap=2)
    assert len(first.enqueued) == 2
    assert len(first.deferred) == 3

    # Next run: the first two are now QUEUED (pending, not re-enqueued);
    # two more of the deferred set get enqueued.
    second = reconciler.reconcile(specs, budget_cap=2)
    assert len(second.enqueued) == 2
    assert len(second.already_pending) == 2
    assert len(second.deferred) == 1
    assert len(queue) == 4  # 2 + 2 published total

    third = reconciler.reconcile(specs, budget_cap=2)
    assert len(third.enqueued) == 1
    assert len(third.already_pending) == 4
    assert len(queue) == 5  # all five eventually enqueued, cap respected each run


def test_budget_cap_zero_is_unlimited() -> None:
    reconciler, _repo, _queue = _build()
    specs = [_spec(f"asset {i}") for i in range(6)]
    outcome = reconciler.reconcile(specs, budget_cap=0)
    assert len(outcome.enqueued) == 6
    assert outcome.budget_remaining == 0  # unlimited reports 0 headroom


def test_negative_budget_rejected() -> None:
    reconciler, _repo, _queue = _build()
    with pytest.raises(ValueError):
        reconciler.reconcile([_spec("x")], budget_cap=-1)


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------


def test_second_run_with_no_changes_enqueues_nothing() -> None:
    reconciler, _repo, queue = _build()
    specs = [_spec(f"asset {i}") for i in range(4)]

    first = reconciler.reconcile(specs)
    assert len(first.enqueued) == 4

    second = reconciler.reconcile(specs)
    assert second.enqueued == ()
    assert len(second.already_pending) == 4
    assert len(queue) == 4  # nothing re-published


def test_failed_assets_are_re_enqueued() -> None:
    reconciler, repo, queue = _build()
    spec = _spec("flaky asset")
    repo.enqueue(spec)
    repo.mark_failed(spec.content_address, "provider exploded")

    outcome = reconciler.reconcile([spec])

    assert outcome.enqueued == (spec.content_address,)
    assert len(queue) == 1


# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------


def test_dry_run_touches_nothing() -> None:
    reconciler, repo, queue = _build()
    specs = [_spec(f"asset {i}") for i in range(3)]

    outcome = reconciler.reconcile(specs, dry_run=True)

    assert len(outcome.enqueued) == 3  # reports what WOULD be enqueued
    assert len(queue) == 0  # but nothing was published
    assert all(repo.get(s.content_address) is None for s in specs)  # and nothing persisted


# ---------------------------------------------------------------------------
# Pre-warming across seasons + de-duplication
# ---------------------------------------------------------------------------


def test_shared_asset_across_seasons_enqueued_once() -> None:
    reconciler, _repo, queue = _build()
    # Same generation inputs (same prompt) in two seasons => same address.
    shared_a = _spec("shared backdrop", asset_id="s1-shared", season_id="season-001")
    shared_b = _spec("shared backdrop", asset_id="s2-shared", season_id="season-002")
    assert shared_a.content_address == shared_b.content_address

    s1 = [shared_a, _spec("s1 only", season_id="season-001")]
    s2 = [shared_b, _spec("s2 only", season_id="season-002")]

    outcome = reconcile_specs_in_order(reconciler, [s1, s2])

    assert outcome.desired == 3  # 4 specs, one shared => 3 unique
    assert len(outcome.enqueued) == 3
    assert len(queue) == 3


def test_prewarm_spends_budget_in_priority_order() -> None:
    reconciler, _repo, _queue = _build()
    current = [_spec(f"current {i}", season_id="season-001") for i in range(3)]
    upcoming = [_spec(f"upcoming {i}", season_id="season-002") for i in range(3)]

    # Budget of 4: the 3 current assets first, then 1 pre-warm of upcoming.
    outcome = reconcile_specs_in_order(reconciler, [current, upcoming], budget_cap=4)

    assert len(outcome.enqueued) == 4
    enqueued = set(outcome.enqueued)
    assert {s.content_address for s in current} <= enqueued  # all current won
    assert len(outcome.deferred) == 2  # two upcoming deferred


# ---------------------------------------------------------------------------
# Manifest loading (validates real stamped content-addresses)
# ---------------------------------------------------------------------------


def test_loads_real_season_001_manifest() -> None:
    manifest = _REPO_ROOT / "content" / "assets-3d" / "season-001" / "assets.manifest.json"
    if not manifest.is_file():
        pytest.skip("content/assets-3d/season-001 manifest not present in this checkout")

    loaded = load_manifest_specs(manifest)

    assert loaded.season_id == "season-001"
    assert len(loaded.specs) >= 1
    for spec in loaded.specs:
        assert spec.season_id == "season-001"
        # from_dict validates each stamped content_address against the
        # recomputed hash; reaching here means they all matched.
        assert spec.content_address.startswith("sha256:")


def test_loaded_manifest_reconciles() -> None:
    manifest = _REPO_ROOT / "content" / "assets-3d" / "season-001" / "assets.manifest.json"
    if not manifest.is_file():
        pytest.skip("content/assets-3d/season-001 manifest not present in this checkout")
    reconciler, _repo, queue = _build()
    loaded = load_manifest_specs(manifest)

    outcome = reconciler.reconcile(loaded.specs, season_id=loaded.season_id)

    assert outcome.desired == len(loaded.specs)
    assert len(outcome.enqueued) == len(loaded.specs)
    assert len(queue) == len(loaded.specs)
    # Idempotent: a second pass enqueues nothing.
    again = reconciler.reconcile(loaded.specs, season_id=loaded.season_id)
    assert again.enqueued == ()
