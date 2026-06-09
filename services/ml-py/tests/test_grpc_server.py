"""Tests for the gRPC TraitScoringService wrapper.

The pure-function scorer is covered by `test_trait_scoring.py`. These
tests exist to lock the proto <-> dataclass translation and the
status-code surface (OK / NOT_FOUND / INVALID_ARGUMENT).
"""

from __future__ import annotations

import json
import time
from collections.abc import Generator
from pathlib import Path

import grpc
import pytest

from app import grpc_server
from app.grpc_gen import trait_scoring_pb2, trait_scoring_pb2_grpc


@pytest.fixture
def content_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    seasons = tmp_path / "seasons"
    sdir = seasons / "season-grpc"
    sdir.mkdir(parents=True)
    season = {
        "id": "season-grpc",
        "title": "GRPC fixture",
        "locale": "en-GB",
        "version": 1,
        "acts": [
            {
                "id": "a-1",
                "name": "Morning",
                "vignettes": [
                    {
                        "id": "v-1",
                        "setting_beat": "",
                        "choices": [
                            {
                                "id": "c-1",
                                "label": "X",
                                "weights": [
                                    {"dimension": "OCEAN-O", "delta": 0.5},
                                    {"dimension": "ATT-SECURE", "delta": 0.25},
                                ],
                            },
                        ],
                    },
                ],
            },
        ],
    }
    (sdir / "season.json").write_text(json.dumps(season))
    # The servicer reads DEFAULT_CONTENT_ROOT through `trait_scoring.score`;
    # patch it for the duration of the test.
    from app.services import trait_scoring

    monkeypatch.setattr(trait_scoring, "DEFAULT_CONTENT_ROOT", seasons)
    return seasons


@pytest.fixture
def grpc_channel(content_root: Path) -> Generator[grpc.Channel, None, None]:
    # Build a bare server ourselves so we can capture the port that
    # `add_insecure_port` selects when given `:0`.
    from concurrent import futures

    from app.grpc_gen import trait_scoring_pb2_grpc

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    trait_scoring_pb2_grpc.add_TraitScoringServiceServicer_to_server(
        grpc_server.TraitScoringServicer(),
        server,
    )
    port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    try:
        channel = grpc.insecure_channel(f"127.0.0.1:{port}")
        grpc.channel_ready_future(channel).result(timeout=5)
        yield channel
        channel.close()
    finally:
        server.stop(grace=0)
        # Give the executor a beat to wind down so the next test starts clean.
        time.sleep(0.05)


def test_score_returns_full_18d_vector(grpc_channel: grpc.Channel) -> None:
    stub = trait_scoring_pb2_grpc.TraitScoringServiceStub(grpc_channel)
    response = stub.Score(
        trait_scoring_pb2.ScoreRequest(
            playthrough_id="pt-1",
            season_id="season-grpc",
            season_version=1,
            events=[
                trait_scoring_pb2.ScoredChoice(vignette_id="v-1", choice_id="c-1"),
            ],
        )
    )
    assert list(response.big_five) == [0.5, 0.0, 0.0, 0.0, 0.0]
    assert list(response.schwartz) == [0.0] * 10
    assert list(response.attachment) == [0.25, 0.0, 0.0]


def test_score_returns_not_found_for_unknown_season(
    grpc_channel: grpc.Channel,
) -> None:
    stub = trait_scoring_pb2_grpc.TraitScoringServiceStub(grpc_channel)
    with pytest.raises(grpc.RpcError) as excinfo:
        stub.Score(
            trait_scoring_pb2.ScoreRequest(
                playthrough_id="pt-1",
                season_id="ghost",
                season_version=1,
                events=[],
            )
        )
    assert excinfo.value.code() == grpc.StatusCode.NOT_FOUND


def test_score_returns_invalid_argument_for_unknown_vignette(
    grpc_channel: grpc.Channel,
) -> None:
    stub = trait_scoring_pb2_grpc.TraitScoringServiceStub(grpc_channel)
    with pytest.raises(grpc.RpcError) as excinfo:
        stub.Score(
            trait_scoring_pb2.ScoreRequest(
                playthrough_id="pt-1",
                season_id="season-grpc",
                season_version=1,
                events=[
                    trait_scoring_pb2.ScoredChoice(vignette_id="v-missing", choice_id="x"),
                ],
            )
        )
    assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
