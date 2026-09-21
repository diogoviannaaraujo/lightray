"""Wire boundary tests and executable checks against published examples."""
import hashlib
import os
from pathlib import Path
import random
import struct

import pytest
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from ng import wire as w


PARAMS = bytes.fromhex("01002301000401312d00020004001e848003000407800438040002003c050001000600020100020008000000006553f100030002010004001801010100020201010304020104050200050303020606030305000201000700100000000df8475800000001a3185c5000")


def pair():
    a, b = os.urandom(28), os.urandom(28)
    return w.Protection(1, a, b), w.Protection(1, b, a)


def test_documented_init_vector():
    private = X25519PrivateKey.from_private_bytes(b"\x11" * 32)
    packet = w.make_init(bytes(range(32)), private, w.Config(mds=256), 0x1122334455667788, PARAMS)
    assert hashlib.sha256(packet).hexdigest() == "c40d8f25fcf2dae5b3f31b911dd784cdcc8cd07913ec078d586a783f717164d1"


def test_handshake_roundtrip_and_transcript_binding():
    psk = os.urandom(32)
    a, b = X25519PrivateKey.generate(), X25519PrivateKey.generate()
    init = w.make_init(psk, a, w.Config())
    config, _ = w.open_init(psk, init)
    assert config.mds == 1200
    response = b"\x81\0" + struct.pack("!I", 9) + b.public_key().public_bytes_raw()
    ka = w.traffic_keys(psk, a, b.public_key().public_bytes_raw(), init, response)
    kb = w.traffic_keys(psk, b, a.public_key().public_bytes_raw(), init, response)
    assert ka == kb and len(set(ka)) == 3
    altered = w.traffic_keys(psk, a, b.public_key().public_bytes_raw(), init[:-1] + bytes([init[-1] ^ 1]), response)
    assert altered != ka


def test_wrong_psk_and_tampered_init_rejected():
    packet = w.make_init(os.urandom(32), X25519PrivateKey.generate(), w.Config())
    with pytest.raises(InvalidTag):
        w.open_init(os.urandom(32), packet)


@pytest.mark.parametrize("index", [0, 3, 4, 8, 12, 16, -1])
def test_authentication_failure_does_not_advance_replay_window(index):
    a, b = pair()
    packet = a.seal(b"hello")
    bad = bytearray(packet)
    bad[index] ^= 1
    with pytest.raises((w.Invalid, InvalidTag)):
        b.open(bytes(bad))
    assert b.highest == -1
    assert b.open(packet)[2] == b"hello"
    with pytest.raises(w.Invalid, match="replay"):
        b.open(packet)


def test_packet_number_wrap_and_reordering():
    a, b = pair()
    a.next_packet = 2**32 - 2
    packets = [a.seal(bytes([i])) for i in range(4)]
    assert b.open(packets[0])[0] == 2**32 - 2
    assert b.open(packets[2])[0] == 2**32
    assert b.open(packets[1])[0] == 2**32 - 1
    assert b.open(packets[3])[0] == 2**32 + 1


def test_replay_window_expiry():
    a, b = pair()
    old = a.seal(b"old")
    a.next_packet = 2048
    b.open(a.seal(b"new"))
    with pytest.raises(w.Invalid, match="replay"):
        b.open(old)


def test_unknown_and_truncated_chunks_are_contained():
    data = w.tlv(199, b"skip") + w.tlv(w.PING, b"1234") + b"\1\xff\xffbad"
    assert w.items(data, strict=False) == [(199, b"skip"), (w.PING, b"1234")]
    with pytest.raises(w.Invalid):
        w.items(data)


def test_feedback_published_bitmap_and_chained_deltas():
    packet = bytes.fromhex("10002300000064000a000f4240dbc0000000190025000d0032000f000a001900010500000003")
    received, count, acks = w.parse_feedback(w.items(packet)[0][1])
    assert count == 10 and acks == [(5, 3)]
    assert received == [(100, 1000000), (101, 1000100), (103, 1000248), (104, 1000300), (106, 1000500), (107, 1000560), (108, 1000600), (109, 1000700)]


def test_feedback_timestamp_wrap_and_clamping():
    body = w.feedback({10: w.MASK - 7, 11: 4, 12: 200_004}, [(0, 3)])
    received, count, acks = w.parse_feedback(body)
    assert received[:2] == [(10, w.MASK - 7), (11, 4)]
    assert received[-1][1] == 4 + 32767 * 4
    assert count == 3 and acks == [(0, 3)]


def test_feedback_long_report_does_not_use_absolute_deltas():
    arrivals = {i: i * 1000 for i in range(500)}
    assert w.parse_feedback(w.feedback(arrivals, []))[0] == list(arrivals.items())


@pytest.mark.parametrize("cut", range(12))
def test_short_feedback_rejected(cut):
    with pytest.raises(w.Invalid):
        w.parse_feedback(bytes(cut))


def test_fragment_last_first_and_original_stride():
    data = b"\1" * 4000
    parts = w.fragments(3, data, 1200)
    decoded = [w.fragment(part) for part in reversed(parts)]
    assert all(stride == 1149 for _, _, _, stride, _ in decoded)
    assert b"".join(payload for _, _, _, _, payload in sorted(decoded, key=lambda part: part[1])) == data
    assert max(len(part) + 35 for part in parts) == 1200


@pytest.mark.parametrize("index,count,stride,payload", [(0, 0, 1, b"x"), (1, 1, 1, b"x"), (0, 1, 0, b"x"), (0, 1, 1, b""), (0, 2, 2, b"x"), (0, 1, 1, b"xx"), (0, 65535, 9000, b"x" * 9000)])
def test_invalid_fragments_rejected_before_allocation(index, count, stride, payload):
    data = struct.pack("!BBIHHHB", 1, 0, 1, index, count, stride, 0) + payload
    with pytest.raises(w.Invalid):
        w.fragment(data)


def test_unknown_fragment_extension_and_unsupported_fec():
    good = struct.pack("!BBIHHHB", 1, 0, 1, 0, 1, 1, 3) + b"\x7f\1\0x"
    assert w.fragment(good)[-1] == b"x"
    with pytest.raises(w.Invalid):
        w.fragment(good[:13] + b"\1\1\1x")


def test_frame_wrap_policy_skips_zero():
    assert w.successor(w.MASK) == 1
    assert w.difference(1, w.MASK) > 0
    assert w.difference(5, w.MASK - 4) == 10


@pytest.mark.parametrize("parser", [w.Frame.decode, w.fragment, w.parse_feedback, w.items])
def test_seeded_malformed_input_never_crashes(parser):
    rng = random.Random(73)
    for _ in range(1000):
        data = rng.randbytes(rng.randrange(300))
        try:
            parser(data)
        except w.Invalid:
            pass


