"""Small automatic smoke suite; the CLI runs the full network measurement matrix."""
import asyncio

import pytest

from ng.demo import SCENARIOS, make_sample, run_scenario
from ng.wire import Config


@pytest.fixture(scope="module")
def sample(tmp_path_factory):
    path = tmp_path_factory.mktemp("udp-hevc") / "source.mp4"
    make_sample(path, 320, 180, 30)
    return path


@pytest.mark.parametrize("name", ["clean", "lost_response", "decoder_reset", "park_resume"])
def test_real_udp_video(name, sample, tmp_path):
    scenario = next(value for value in SCENARIOS if value.name == name)
    result = asyncio.run(run_scenario(scenario, sample, Config(width=320, height=180), 3, 20260921, tmp_path))
    assert result["passed"], result["failures"]
    assert result["frames_decoded"] > 50
    assert result["pixel_mismatches"] == 0


def test_encoding_in_flight_during_park(sample, tmp_path, monkeypatch):
    import time
    from ng.media import Encoder
    original = Encoder.encode

    def slow_encode(self, force_idr):
        time.sleep(.008)
        return original(self, force_idr)

    monkeypatch.setattr(Encoder, "encode", slow_encode)
    scenario = next(value for value in SCENARIOS if value.name == "park_resume")
    result = asyncio.run(run_scenario(scenario, sample, Config(width=320, height=180), 6, 20260921, tmp_path))
    assert result["passed"], result["failures"]
    assert result["host"].get("encode_cancelled_on_transition", 0) >= 1
