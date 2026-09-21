"""Validate published vectors directly from the protocol documentation."""
from pathlib import Path
import re

from ng import wire as w
from ng.media import Decoder
from test_wire import PARAMS


DOCS = Path(__file__).resolve().parents[2] / "docs"


def hex_blocks(name):
    text = (DOCS / name).read_text()
    for block in re.findall(r"```\n(.*?)\n```", text, flags=re.DOTALL):
        compact = "".join(block.split())
        if compact and re.fullmatch("[0-9a-fA-F]+", compact):
            yield bytes.fromhex(compact)


def test_vectors_still_match_the_documentation_under_review():
    assert PARAMS in list(hex_blocks("handshake.md"))
    assert bytes.fromhex("10002300000064000a000f4240dbc0000000190025000d0032000f000a001900010500000003") in list(hex_blocks("feedback.md"))


def test_published_idr_decodes():
    data = next(block for block in hex_blocks("video.md") if len(block) == 423)
    frame = w.Frame.decode(data)
    decoded = Decoder().decode(frame)
    assert (decoded.width, decoded.height) == (16, 16)


def test_published_fragment_and_protected_datagram():
    fragment = next(block for block in hex_blocks("video.md") if block[:3] == bytes.fromhex("010018"))
    parts = w.items(fragment)
    assert len(parts) == 1 and parts[0][0] == w.MEDIA
    _, index, count, stride, payload = w.fragment(parts[0][1])
    assert (index, count, stride, len(payload)) == (4, 5, 1149, 8)
    packet = next(block for block in hex_blocks("packets.md") if len(block) == 59)
    keys = bytes.fromhex("80345064aa0e8da5832ecea08d61f44b448d50b586820bc6f220a19c")
    protection = w.Protection(0xabcd1234, keys, keys)
    number, timestamp, plaintext, _ = protection.open(packet)
    assert (number, timestamp, plaintext) == (7, 2500000, fragment)


def test_published_ltr_header_lengths():
    blocks = list(hex_blocks("video.md"))
    specific = bytes.fromhex("0102000000000100000005000010920000")
    any_reference = bytes.fromhex("01030000000001000000050000")
    assert specific in blocks and any_reference in blocks
    assert len(specific) - len(any_reference) == 4
    assert "four bytes shorter" in (DOCS / "video.md").read_text()
