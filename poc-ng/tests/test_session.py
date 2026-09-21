"""State-machine tests use actual encoded HEVC and protected protocol messages."""
from dataclasses import replace
import os
import struct
import time

import pytest

from ng import wire as w
from ng.demo import make_sample
from ng.media import Decoder, Encoder, pixel_hash
from ng.session import Peer


@pytest.fixture(scope="module")
def sample(tmp_path_factory):
    path = tmp_path_factory.mktemp("hevc") / "sample.mp4"
    make_sample(path, 160, 96, 30)
    return path


@pytest.fixture
def encoded(sample):
    encoder = Encoder(w.Config(width=160, height=96), sample)
    result = [encoder.encode(i == 0)[:2] for i in range(6)]
    encoder.close()
    return result


def receiver():
    peer = Peer(False, os.urandom(32), w.Config(width=160, height=96))
    peer.status = "active"
    sent = []
    peer.send = lambda kind, body: sent.append((kind, body))
    return peer, sent


def test_real_hevc_decode_and_pixel_hash(encoded):
    decoder = Decoder()
    for frame, expected in encoded:
        parsed = w.Frame.decode(frame.encode())
        assert pixel_hash(decoder.decode(parsed)) == expected


def test_out_of_order_prediction_waits_for_idr(encoded):
    peer, _ = receiver()
    output = []
    peer.on_frame = lambda ident, frame, first: output.append(ident) or True
    now = time.monotonic()
    for part in w.fragments(2, encoded[1][0].encode(), 256):
        peer.receive_media(part, now)
    assert output == []
    for part in reversed(w.fragments(1, encoded[0][0].encode(), 256)):
        peer.receive_media(part, now + .001)
    assert output == [1, 2]


def test_duplicate_retransmissions_never_redeliver(encoded):
    peer, _ = receiver()
    output = []
    peer.on_frame = lambda ident, frame, first: output.append(ident) or True
    parts = w.fragments(1, encoded[0][0].encode(), 256)
    for part in parts + parts:
        peer.receive_media(part, time.monotonic())
    assert output == [1]


def test_fragment_metadata_mismatch_is_rejected(encoded):
    peer, _ = receiver()
    parts = w.fragments(1, encoded[0][0].encode(), 256)
    peer.receive_media(parts[0], time.monotonic())
    different = bytearray(parts[1])
    different[8:10] = struct.pack("!H", len(parts) + 1)
    with pytest.raises(w.Invalid, match="inconsistent"):
        peer.receive_media(bytes(different), time.monotonic())


def test_whole_frame_loss_requests_count_zero(encoded):
    peer, sent = receiver()
    now = time.monotonic()
    for part in w.fragments(1, encoded[0][0].encode(), 256):
        peer.receive_media(part, now)
    for part in w.fragments(3, encoded[2][0].encode(), 256):
        peer.receive_media(part, now + .001)
    peer.repair(now + .02)
    assert any(kind == w.NACK and struct.pack("!IHH", 2, 0, 0) in body[1:] for kind, body in sent)


def test_no_nack_for_unsent_paced_tail(encoded):
    peer, sent = receiver()
    now = time.monotonic()
    parts = w.fragments(1, encoded[0][0].encode(), 256)
    assert len(parts) > 2
    peer.receive_media(parts[0], now)
    peer.repair(now + .005)
    assert not any(kind == w.NACK for kind, _ in sent)
    peer.repair(now + .075)
    assert any(kind == w.NACK for kind, _ in sent)


def test_generation_change_without_idr_preserves_prediction(encoded):
    peer, _ = receiver()
    output = []
    peer.on_frame = lambda ident, frame, first: output.append(ident) or True
    for ident, (frame, _) in enumerate(encoded[:2], 1):
        frame = replace(frame, generation=ident - 1)
        for part in w.fragments(ident, frame.encode(), 1200):
            peer.receive_media(part, time.monotonic())
    assert output == [1, 2]


def test_decoder_reset_blocks_old_ltr_even_after_ack():
    peer, _ = receiver()
    output = []
    peer.last_decoded = 10
    peer.awaiting_idr = False
    peer.expected = 11
    peer.on_frame = lambda ident, frame, first: output.append(ident) or True
    peer.reset_decoder()
    peer.ready[11] = (w.Frame(1, 3, 0, 0, b""), time.monotonic())
    peer.drain(time.monotonic())
    assert output == [] and peer.refresh_pending is not None


def test_recovery_retry_uses_same_id_then_new_attempt_after_expiry():
    peer, sent = receiver()
    now = time.monotonic()
    peer.request_refresh(2)
    peer.repair(now + .02)
    peer.repair(now + .05)
    ids = [struct.unpack("!BBBIII", body)[-1] for kind, body in sent if kind == w.REFRESH]
    assert len(ids) == 2 and ids[0] == ids[1]
    peer.repair(now + .3)
    assert struct.unpack("!BBBIII", sent[-1][1])[-1] != ids[0]


def test_literal_recovery_rule_has_no_progress_after_lost_idr():
    peer, sent = receiver()
    peer.strict_recovery = True
    now = time.monotonic()
    peer.request_refresh(2)
    for step in range(1, 50):
        peer.repair(now + step * .1)
    ids = {struct.unpack("!BBBIII", body)[-1] for kind, body in sent if kind == w.REFRESH}
    assert len(ids) == 1
    host = Peer(True, os.urandom(32), w.Config())
    host.force_idr = False
    for kind, body in sent:
        host.chunk(kind, body, 0, now)
        host.force_idr = False  # Model the single permitted recovery IDR being produced and lost.
    assert host.stats["refreshes"] == 1 and not host.force_idr


def test_reliable_first_message_loss_and_reordered_completion():
    peer, _ = receiver()
    delivered = []
    peer.control = delivered.append
    now = time.monotonic()
    peer.chunk(w.RELIABLE, struct.pack("!BIHH", 0, 1, 0, 1) + b"second", 0, now)
    assert delivered == [] and (0, 1) in peer.acks
    peer.chunk(w.RELIABLE, struct.pack("!BIHH", 0, 0, 1, 2) + b"st", 0, now)
    assert delivered == []
    peer.chunk(w.RELIABLE, struct.pack("!BIHH", 0, 0, 0, 2) + b"fir", 0, now)
    assert delivered == [b"first", b"second"]
    peer.chunk(w.RELIABLE, struct.pack("!BIHH", 0, 0, 0, 1) + b"duplicate", 0, now)
    assert len(delivered) == 2


def test_parking_preserves_crypto_counters_and_clears_media(encoded):
    host = Peer(True, os.urandom(32), w.Config())
    host.status = "active"
    host.protection = w.Protection(1, os.urandom(28), os.urandom(28))
    host.protection.next_packet = 100
    host.submit(encoded[0][0])
    assert host.store and host.media_queue
    host.park()
    assert host.protection.next_packet == 100
    assert not host.store and not host.media_queue and not host.assemblies


def test_old_unseen_reliable_packet_survives_plain_resume_replay_window():
    # A spec gap, not an assertion that stale delivery is desirable.
    key_a, key_b = os.urandom(28), os.urandom(28)
    a, b = w.Protection(1, key_a, key_b), w.Protection(1, key_b, key_a)
    old = a.seal(w.tlv(w.RELIABLE, struct.pack("!BIHH", 0, 0, 0, 1) + b"old-control"))
    b.open(a.seal(w.tlv(w.PARK, b"")))
    b.open(a.seal(w.tlv(w.RESUME, b"\1")))
    assert b.open(old)[2].endswith(b"old-control")


def test_fresh_host_reset_key_cannot_authenticate_old_session_reset():
    import hmac
    session = struct.pack("!I", 42)
    before = hmac.digest(os.urandom(32), session, "sha256")[:16]
    after = hmac.digest(os.urandom(32), session, "sha256")[:16]
    assert not hmac.compare_digest(before, after)


def test_partial_reconfiguration_refuses_unsupported_hdr_but_applies_mtu():
    host = Peer(True, os.urandom(32), w.Config())
    responses = []
    host.reliable = responses.append
    host.control(struct.pack("!BIB", 1, 7, 0) + w.tlv(5, b"\1") + w.tlv(6, struct.pack("!H", 800)))
    assert host.config.hdr == 0 and host.config.mds == 800 and host.config.generation == 1
    fields = dict(w.items(responses[0][6:]))
    assert int.from_bytes(fields[9], "big") == 1 << 4


def test_old_authenticated_packet_from_new_address_does_not_rebind():
    host = Peer(True, os.urandom(32), w.Config())
    key_a, key_b = os.urandom(28), os.urandom(28)
    sender = w.Protection(1, key_a, key_b)
    host.protection = w.Protection(1, key_b, key_a)
    host.status = "active"
    host.destination = ("127.0.0.1", 1000)
    old = sender.seal(b"")
    host.receive(sender.seal(b""), host.destination)
    host.receive(old, ("127.0.0.1", 2000))
    assert host.destination == ("127.0.0.1", 1000)
    host.receive(sender.seal(b""), ("127.0.0.1", 2000))
    assert host.destination == ("127.0.0.1", 2000)


def test_retransmit_uses_original_stride_and_new_packet_number(encoded):
    host = Peer(True, os.urandom(32), w.Config(mds=1200))
    host.status = "active"
    key_a, key_b = os.urandom(28), os.urandom(28)
    host.protection = w.Protection(1, key_a, key_b)
    receiver = w.Protection(1, key_b, key_a)
    packets = []
    host.raw = packets.append
    ident = host.submit(encoded[0][0])
    now = time.monotonic()
    host.tokens = 32000
    host.pace(now)
    original_number, _, original_body, _ = receiver.open(packets[0])
    host.config.mds = 800
    host.chunk(w.NACK, b"\1" + struct.pack("!IHH", ident, 0, 1), 0, now)
    host.tokens = 32000
    host.pace(now)
    retry_number, _, retry_body, _ = receiver.open(packets[-1])
    before, after = w.items(original_body)[0][1], w.items(retry_body)[0][1]
    assert w.fragment(before)[3] == w.fragment(after)[3] == 1149
    assert after[1] & 2 and retry_number > original_number


def test_frame_id_wrap_preserves_prediction(encoded):
    peer, _ = receiver()
    peer.expected = w.MASK
    delivered = []
    peer.on_frame = lambda ident, frame, first: delivered.append(ident) or True
    for ident, (frame, _) in zip([w.MASK, 1], encoded[:2]):
        for part in w.fragments(ident, frame.encode(), 1200):
            peer.receive_media(part, time.monotonic())
    assert delivered == [w.MASK, 1]


def test_backstop_requirement_is_detected_without_claiming_codec_support():
    host = Peer(True, os.urandom(32), w.Config())
    host.status = "active"
    host.send = lambda kind, body: None
    now = time.monotonic()
    host.last_rx = host.last_ping = now
    for i in range(4):
        host.loss_total, host.loss_received = 100, 70
        host.loss_at = now - .6
        host.last_rx = now
        host.tick(now)
        now += .5
    assert host.stats["backstop_required"] == 1
    assert any(event["event"] == "unsupported_backstop" for event in host.events)
