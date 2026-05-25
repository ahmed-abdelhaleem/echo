"""gRPC tests for the M1 Portrait + Reflection servicers.

These lock the proto <-> dataclass translation so a `make proto`
regen doesn't silently break the wire format.
"""

from __future__ import annotations

import time
from collections.abc import Generator
from concurrent import futures

import grpc
import pytest

from app import grpc_server
from app.grpc_gen import (
    portrait_gen_pb2,
    portrait_gen_pb2_grpc,
    reflection_gen_pb2,
    reflection_gen_pb2_grpc,
)


@pytest.fixture
def grpc_channel() -> Generator[grpc.Channel, None, None]:
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    portrait_gen_pb2_grpc.add_PortraitGenServiceServicer_to_server(
        grpc_server.PortraitGenServicer(),
        server,
    )
    reflection_gen_pb2_grpc.add_ReflectionGenServiceServicer_to_server(
        grpc_server.ReflectionGenServicer(),
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
        time.sleep(0.05)


# --- PortraitGenService -----------------------------------------------------


def test_portrait_generate_returns_inline_png(grpc_channel: grpc.Channel) -> None:
    stub = portrait_gen_pb2_grpc.PortraitGenServiceStub(grpc_channel)
    resp = stub.Generate(
        portrait_gen_pb2.GeneratePortraitRequest(
            playthrough_id="pt-1",
            seed=0,
            big_five=[0.5, 0.0, 0.0, 0.0, 0.0],
            schwartz=[0.0] * 10,
            attachment=[0.0, 0.0, 0.0],
        ),
    )
    assert resp.png.startswith(b"\x89PNG\r\n\x1a\n")
    assert resp.renderer_version == 1
    assert resp.static_png_key == ""
    assert resp.animated_webp_key == ""


def test_portrait_invalid_dimension_count_raises_invalid_argument(
    grpc_channel: grpc.Channel,
) -> None:
    stub = portrait_gen_pb2_grpc.PortraitGenServiceStub(grpc_channel)
    with pytest.raises(grpc.RpcError) as excinfo:
        stub.Generate(
            portrait_gen_pb2.GeneratePortraitRequest(
                playthrough_id="pt-1",
                seed=0,
                big_five=[0.0, 0.0, 0.0, 0.0],  # only 4 values
                schwartz=[0.0] * 10,
                attachment=[0.0, 0.0, 0.0],
            ),
        )
    assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT


# --- ReflectionGenService ---------------------------------------------------


def test_reflection_generate_returns_trait_derived_text(
    grpc_channel: grpc.Channel,
) -> None:
    stub = reflection_gen_pb2_grpc.ReflectionGenServiceStub(grpc_channel)
    resp = stub.Generate(
        reflection_gen_pb2.GenerateReflectionRequest(
            playthrough_id="pt-1",
            youth_safe=False,
            locale="en-GB",
            big_five=[0.9, 0.0, 0.0, 0.0, 0.0],  # OCEAN-O dominant
            schwartz=[0.0] * 10,
            attachment=[0.0, 0.0, 0.0],
        ),
    )
    assert "you reach toward what is unfamiliar" in resp.text
    assert resp.template_id.startswith("m1-stub.")
    assert resp.used_fallback is False


def test_reflection_invalid_dimension_count_raises_invalid_argument(
    grpc_channel: grpc.Channel,
) -> None:
    stub = reflection_gen_pb2_grpc.ReflectionGenServiceStub(grpc_channel)
    with pytest.raises(grpc.RpcError) as excinfo:
        stub.Generate(
            reflection_gen_pb2.GenerateReflectionRequest(
                playthrough_id="pt-1",
                youth_safe=False,
                locale="en-GB",
                big_five=[0.0, 0.0, 0.0, 0.0, 0.0],
                schwartz=[0.0] * 9,  # only 9
                attachment=[0.0, 0.0, 0.0],
            ),
        )
    assert excinfo.value.code() == grpc.StatusCode.INVALID_ARGUMENT
