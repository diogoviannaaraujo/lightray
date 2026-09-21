"""Lightray v0 wire shapes and cryptography from docs/, without older PoC imports."""
from dataclasses import dataclass
import hashlib
import hmac
import struct
import time

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF, HKDFExpand

MASK = 0xFFFFFFFF
MEDIA, RELIABLE, FEEDBACK, NACK, ACK, REFRESH = 1, 2, 16, 17, 18, 19
PING, PONG, PARK, RESUME, CLOSE = 48, 49, 50, 51, 52


class Invalid(ValueError):
    """Malformed or inadmissible wire input; callers count and discard it."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Invalid(message)


def us() -> int:
    return time.monotonic_ns() // 1000 & MASK


def difference(a: int, b: int) -> int:
    return ((a - b + 2**31) & MASK) - 2**31


def successor(value: int) -> int:
    # Experiment policy: skip the reserved zero on frame-ID wrap (spec ambiguity).
    return (value + 1) & MASK or 1


def tlv(kind: int, body: bytes) -> bytes:
    return struct.pack("!BH", kind, len(body)) + body


def items(data: bytes, *, strict: bool = True, tiny: bool = False) -> list[tuple[int, bytes]]:
    result = []
    offset, header = 0, 2 if tiny else 3
    while offset + header <= len(data):
        kind = data[offset]
        size = data[offset + 1] if tiny else int.from_bytes(data[offset + 1:offset + 3], "big")
        offset += header
        if offset + size > len(data):
            require(not strict, "truncated TLV")
            return result
        result.append((kind, data[offset:offset + size]))
        offset += size
    require(not strict or offset == len(data), "trailing TLV bytes")
    return result


@dataclass
class Config:
    bitrate: int = 1_000_000
    floor: int = 100_000
    width: int = 640
    height: int = 360
    fps: int = 30
    hdr: int = 0
    mds: int = 1200
    generation: int = 0

    def encode(self, flags: int = 0, rejected: int = 0) -> bytes:
        values = [(1, struct.pack("!I", self.bitrate)), (2, struct.pack("!I", self.floor)),
                  (3, struct.pack("!HH", self.width, self.height)), (4, struct.pack("!H", self.fps)),
                  (5, bytes([self.hdr])), (6, struct.pack("!H", self.mds)),
                  (7, struct.pack("!I", self.generation)), (8, bytes([flags])),
                  (9, struct.pack("!I", rejected))]
        return b"".join(tlv(kind, body) for kind, body in values)

    @classmethod
    def decode(cls, data: bytes) -> "Config":
        result = cls()
        formats = {1: ("bitrate", 4), 2: ("floor", 4), 4: ("fps", 2), 5: ("hdr", 1), 6: ("mds", 2), 7: ("generation", 4)}
        for kind, body in items(data):
            if kind == 3:
                require(len(body) == 4, "resolution width")
                result.width, result.height = struct.unpack("!HH", body)
            elif kind in formats:
                name, size = formats[kind]
                require(len(body) == size, "configuration width")
                setattr(result, name, int.from_bytes(body, "big"))
        require(100_000 <= result.bitrate <= 500_000_000 and 100_000 <= result.floor <= result.bitrate, "bitrate range")
        require(result.width >= 16 and result.height >= 16 and 1 <= result.fps <= 240, "video range")
        require(result.hdr in (0, 1) and 256 <= result.mds <= 9000, "configuration range")
        return result


STREAMS = bytes([1, 1, 1, 0])  # One host-to-client MEDIA/VIDEO stream, plus implicit stream 0.


def parameters(config: Config, *, timestamp: int | None = None, token: bytes | None = None, grace: float = 1800) -> bytes:
    body = tlv(1, config.encode()) + tlv(3, b"\0\0") + tlv(4, STREAMS) + tlv(5, struct.pack("!H", config.mds))
    body += tlv(7, struct.pack("!QQ", 60_000_000_000, int(grace * 1e9)))
    if timestamp is not None:
        body += tlv(2, struct.pack("!Q", timestamp))
    if token is not None:
        body += tlv(8, token)
    return body


def parse_parameters(data: bytes, response: bool) -> tuple[Config, dict[int, bytes]]:
    fields: dict[int, bytes] = {}
    for kind, body in items(data):
        require(kind not in fields or kind not in range(1, 9), "duplicate handshake TLV")
        fields[kind] = body
    require({1, 3, 4, 5} <= fields.keys(), "missing handshake TLV")
    require(len(fields[3]) == 2 and fields[3][1] == 0, "capabilities width/FEC")
    table = fields[4]
    require(4 <= len(table) <= 128 and len(table) % 4 == 0, "stream table size")
    ids = set()
    for offset in range(0, len(table), 4):
        stream, kind, direction, delivery = table[offset:offset + 4]
        require(stream != 0 and stream not in ids and 1 <= kind <= 6 and 1 <= direction <= 3 and delivery <= 3, "stream entry")
        ids.add(stream)
    config = Config.decode(fields[1])
    require(len(fields[5]) == 2 and int.from_bytes(fields[5], "big") == config.mds, "conflicting datagram size")
    if response:
        require(2 not in fields and len(fields.get(8, b"")) == 16, "response parameters")
    else:
        require(len(fields.get(2, b"")) == 8, "missing timestamp")
    if 7 in fields:
        require(len(fields[7]) == 16, "lifecycle width")
    return config, fields


def init_keys(psk: bytes, prefix: bytes) -> bytes:
    context = b"lightray-v0 init" + prefix[1:2] + prefix[4:44]
    return HKDF(hashes.SHA256(), 28, hashlib.sha256(context).digest(), b"lightray-v0 init").derive(psk)


def make_init(psk: bytes, private: X25519PrivateKey, config: Config, pairing: int = 1, params: bytes | None = None) -> bytes:
    prefix = struct.pack("!BBHQ", 128, 0, 0, pairing) + private.public_key().public_bytes_raw()
    fields = parameters(config, timestamp=int(time.time())) if params is None else params
    body = struct.pack("!H", len(fields)) + fields
    require(len(body) <= config.mds - 60, "INIT parameters exceed datagram")
    keys = init_keys(psk, prefix)
    return prefix + AESGCM(keys[:16]).encrypt(keys[16:], body.ljust(config.mds - 60, b"\0"), prefix)


def open_init(psk: bytes, packet: bytes, pairing: int = 1) -> tuple[Config, dict[int, bytes]]:
    require(256 <= len(packet) <= 9000 and packet[:2] == b"\x80\0", "INIT envelope")
    require(int.from_bytes(packet[4:12], "big") == pairing, "pairing mismatch")
    keys = init_keys(psk, packet[:44])
    body = AESGCM(keys[:16]).decrypt(keys[16:], packet[44:], packet[:44])
    require(len(body) >= 2, "INIT length")
    size = int.from_bytes(body[:2], "big")
    require(size <= len(body) - 2, "INIT parameter length")
    config, fields = parse_parameters(body[2:2 + size], False)
    require(config.mds == len(packet), "INIT padding size")
    return config, fields


def traffic_keys(psk: bytes, private: X25519PrivateKey, peer: bytes, init: bytes, response_prefix: bytes) -> tuple[bytes, bytes, bytes]:
    dh = private.exchange(X25519PublicKey.from_public_bytes(peer))
    transcript = hashlib.sha256(init + response_prefix).digest()
    prk = hmac.digest(transcript, psk + dh, "sha256")
    return tuple(HKDFExpand(hashes.SHA256(), 28, b"lightray-v0 " + label).derive(prk) for label in (b"response", b"client", b"host"))


class Protection:
    def __init__(self, session: int, tx: bytes, rx: bytes):
        self.session, self.tx, self.rx = session, tx, rx
        self.next_packet = 0
        self.highest = -1
        self.window = 0

    @staticmethod
    def nonce(keys: bytes, number: int) -> bytes:
        return (int.from_bytes(keys[16:], "big") ^ number).to_bytes(12, "big")

    def seal(self, body: bytes, timestamp: int | None = None) -> bytes:
        require(self.next_packet < 2**64, "packet number exhausted")
        number = self.next_packet
        self.next_packet += 1
        header = struct.pack("!IIII", 0, self.session, number & MASK, us() if timestamp is None else timestamp)
        return header + AESGCM(self.tx[:16]).encrypt(self.nonce(self.tx, number), body, header)

    def open(self, packet: bytes) -> tuple[int, int, bytes, bool]:
        require(len(packet) >= 32 and packet[0] < 128, "protected envelope")
        _, session, low, timestamp = struct.unpack("!IIII", packet[:16])
        require(session == self.session, "session mismatch")
        expected = self.highest + 1
        number = (expected & ~MASK) | low
        if number + 2**31 <= expected and number + 2**32 < 2**64:
            number += 2**32
        elif number > expected + 2**31 and number >= 2**32:
            number -= 2**32
        distance = self.highest - number
        require(distance < 2048 and (distance < 0 or not self.window & (1 << distance)), "replay")
        body = AESGCM(self.rx[:16]).decrypt(self.nonce(self.rx, number), packet[16:], packet[:16])
        newest = number > self.highest
        if newest:
            self.window = ((self.window << min(number - self.highest, 2048)) | 1) & ((1 << 2048) - 1)
            self.highest = number
        else:
            self.window |= 1 << distance
        return number, timestamp, body, newest


def length_prefixed(nals: list[bytes]) -> bytes:
    return b"".join(struct.pack("!I", len(nal)) + nal for nal in nals)


def nals(data: bytes) -> list[bytes]:
    result = []
    offset = 0
    while offset < len(data):
        require(offset + 4 <= len(data), "truncated NAL length")
        size = int.from_bytes(data[offset:offset + 4], "big")
        offset += 4
        require(size >= 2 and offset + size <= len(data), "invalid NAL length")
        result.append(data[offset:offset + size])
        offset += size
    return result


@dataclass
class Frame:
    kind: int
    reference: int
    generation: int
    capture: int
    payload: bytes
    codec: bytes = b""
    flags: int = 0
    reference_id: int = 0

    def encode(self) -> bytes:
        ext = tlv(1, self.codec) if self.codec else b""
        header = struct.pack("!BBBII", self.kind, self.reference, self.flags, self.generation, self.capture)
        if self.reference == 2:
            header += struct.pack("!I", self.reference_id)
        return header + struct.pack("!H", len(ext)) + ext + self.payload

    @classmethod
    def decode(cls, data: bytes) -> "Frame":
        require(len(data) >= 13, "frame header")
        kind, reference, flags, generation, capture = struct.unpack("!BBBII", data[:11])
        require(kind in (0, 1) and reference <= 3, "video frame enum")
        offset, reference_id = 11, 0
        if reference == 2:
            require(len(data) >= 17, "LTR header")
            reference_id = int.from_bytes(data[11:15], "big")
            offset = 15
        size = int.from_bytes(data[offset:offset + 2], "big")
        offset += 2
        require(offset + size <= len(data), "frame extension length")
        extensions = dict(items(data[offset:offset + size]))
        codec = extensions.get(1, b"")
        if kind == 0:
            require(bool(codec), "IDR missing CODEC_CONFIG")
            sets = nals(codec)
            require(len(sets) == 3 and [nal[0] >> 1 & 63 for nal in sets] == [32, 33, 34], "HEVC parameter sets")
        payload = data[offset + size:]
        require(bool(nals(payload)), "empty access unit")
        return cls(kind, reference, generation, capture, payload, codec, flags, reference_id)


def fragments(frame_id: int, frame: bytes, mds: int) -> list[bytes]:
    stride = mds - 51
    count = (len(frame) + stride - 1) // stride
    require(0 < frame_id <= MASK and 0 < count <= 65535, "frame size/id")
    keyframe = frame[0] == 0
    return [struct.pack("!BBIHHHB", 1, int(keyframe) | (4 if i == 0 else 0), frame_id, i, count, stride, 3) + b"\1\1\0" + frame[i * stride:(i + 1) * stride] for i in range(count)]


def fragment(data: bytes) -> tuple[int, int, int, int, bytes]:
    require(len(data) >= 13, "fragment header")
    stream, _, frame_id, index, count, stride, size = struct.unpack("!BBIHHHB", data[:13])
    require(stream == 1 and frame_id != 0, "fragment stream/id")
    require(13 + size <= len(data), "fragment extension length")
    for kind, value in items(data[13:13 + size], tiny=True):
        if kind == 1:
            require(value == b"\0", "unsupported FEC")
    payload = data[13 + size:]
    require(count > 0 and index < count and stride > 0, "fragment dimensions")
    require(0 < len(payload) <= stride and (index == count - 1 or len(payload) == stride), "fragment payload size")
    require(count * stride <= 8 * 1024 * 1024, "frame memory bound")
    return frame_id, index, count, stride, payload


def feedback(arrivals: dict[int, int], acknowledgements: list[tuple[int, int]]) -> bytes:
    numbers = sorted(arrivals)
    base = numbers[0] if numbers else 0
    count = numbers[-1] - base + 1 if numbers else 0
    require(count <= 65535, "feedback range")
    bitmap = bytearray((count + 7) // 8)
    previous = arrivals[base] if numbers else 0
    deltas = bytearray()
    for number in numbers:
        index = number - base
        bitmap[index // 8] |= 1 << (7 - index % 8)
        delta = max(-32768, min(32767, difference(arrivals[number], previous) // 4))
        deltas += struct.pack("!h", delta)
        previous = arrivals[number]
    return struct.pack("!IHI", base & MASK, count, arrivals[base] if numbers else 0) + bitmap + deltas + struct.pack("!H", len(acknowledgements)) + b"".join(struct.pack("!BI", *ack) for ack in acknowledgements)


def parse_feedback(data: bytes) -> tuple[list[tuple[int, int]], int, list[tuple[int, int]]]:
    require(len(data) >= 12, "feedback header")
    base, count, arrival = struct.unpack("!IHI", data[:10])
    offset = 10 + (count + 7) // 8
    require(offset + 2 <= len(data), "feedback bitmap")
    received = []
    for i in range(count):
        if data[10 + i // 8] & (1 << (7 - i % 8)):
            require(offset + 2 <= len(data), "feedback delta")
            arrival = (arrival + struct.unpack("!h", data[offset:offset + 2])[0] * 4) & MASK
            received.append(((base + i) & MASK, arrival))
            offset += 2
    require(offset + 2 <= len(data), "feedback ack count")
    ack_count = int.from_bytes(data[offset:offset + 2], "big")
    offset += 2
    require(ack_count <= 256 and offset + ack_count * 5 == len(data), "feedback trailer")
    acks = [struct.unpack("!BI", data[i:i + 5]) for i in range(offset, len(data), 5)]
    return received, count, acks
