"""Single-video-stream experiment: handshake, paced media, repair and reliable control."""
from collections import Counter, OrderedDict, deque
from dataclasses import dataclass, field, replace
import hashlib
import hmac
import os
import struct
import time
from typing import Callable

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import wire as w
from .network import Address, Port, open_port


@dataclass
class Assembly:
    count: int
    stride: int
    started: float
    last: float
    parts: dict[int, bytes] = field(default_factory=dict)
    nack_at: float = 0


class Peer:
    def __init__(self, host: bool, psk: bytes, config: w.Config, *, strict_recovery: bool = False):
        self.host, self.psk, self.config = host, psk, replace(config)
        self.strict_recovery = strict_recovery
        self.port: Port | None = None
        self.destination: Address | None = None
        self.protection: w.Protection | None = None
        self.status = "new"
        self.stats: Counter[str] = Counter()
        self.events: list[dict[str, object]] = []
        self.on_frame: Callable[[int, w.Frame, float], bool] = lambda ident, frame, arrival: True
        self.on_config: Callable[[w.Config], None] = lambda config: None
        self.on_reset: Callable[[], None] = lambda: None
        self.private = X25519PrivateKey.generate()
        self.init = b""
        self.init_at = 0.0
        self.init_attempts = 0
        self.cache: OrderedDict[bytes, tuple[float, bytes]] = OrderedDict()
        self.reset_key = os.urandom(32)
        self.token = b""
        self.expired_session: int | None = None
        self.grace = 1800.0
        self.last_rx = time.monotonic()
        self.parked_at = 0.0
        self.resume_at = 0.0
        self.resume_attempts = 0
        self.last_ping = 0.0
        self.pings: dict[int, float] = {}
        self.rtt = 0.01
        self.last_feedback = 0.0
        self.feedback_needed = False
        self.arrivals: dict[int, int] = {}
        self.sent: OrderedDict[int, float] = OrderedDict()
        self.acks: set[tuple[int, int]] = set()
        self.reliable_tx = 0
        self.reliable_rx = 0
        self.reliable_pending: dict[int, tuple[bytes, float, float]] = {}
        self.reliable_ready: dict[int, bytes] = {}
        self.reliable_parts: dict[int, tuple[int, dict[int, bytes]]] = {}
        self.refresh_seen: deque[int] = deque(maxlen=256)
        self.refresh_pending: tuple[int, int, int, float, float] | None = None
        self.request_id = 0
        self.force_idr = True
        self.next_frame = 1
        self.expected = 1
        self.last_decoded = 0
        self.awaiting_idr = True
        self.assemblies: dict[int, Assembly] = {}
        self.missing: dict[int, tuple[float, float]] = {}
        self.ready: dict[int, tuple[w.Frame, float]] = {}
        self.completed: deque[int] = deque(maxlen=256)
        self.store: OrderedDict[int, tuple[list[bytes], float]] = OrderedDict()
        self.store_bytes = 0
        self.retransmit_at: dict[tuple[int, int], float] = {}
        self.media_queue: deque[tuple[bytes, float]] = deque()
        self.repair_queue: deque[tuple[bytes, float]] = deque()
        self.tokens = 0.0
        self.pacer_at = time.monotonic()
        self.pacer_rate = config.bitrate / 8 * 1.25
        self.loss_windows: deque[float] = deque(maxlen=4)
        self.loss_at = time.monotonic()
        self.loss_received = self.loss_total = 0
        self.backstop = False
        self.failures: list[str] = []

    def event(self, kind: str, **details: object) -> None:
        self.events.append({"time": time.monotonic(), "event": kind, **details})

    async def open(self) -> None:
        self.port = await open_port(self.receive)

    async def rebind(self) -> None:
        old = self.port
        await self.open()
        if old:
            old.close()
        self.event("socket_replaced", port=self.port.address[1])

    def raw(self, data: bytes, destination: Address | None = None) -> None:
        if self.port is None or (destination or self.destination) is None:
            raise RuntimeError("peer has no socket/destination")
        self.port.send(data, destination or self.destination)
        self.stats["datagrams_sent"] += 1
        self.stats["bytes_sent"] += len(data)

    def send(self, kind: int, body: bytes) -> None:
        if self.protection is None:
            raise RuntimeError("protected send before handshake")
        packet = self.protection.seal(w.tlv(kind, body))
        # Old-stride media retransmissions are allowed after an MTU reconfiguration.
        w.require(len(packet) <= self.config.mds or kind == w.MEDIA, "datagram budget")
        self.sent[(self.protection.next_packet - 1) & w.MASK] = time.monotonic()
        while len(self.sent) > 8192:
            self.sent.popitem(last=False)
        self.raw(packet)

    def start(self) -> None:
        self.private = X25519PrivateKey.generate()
        self.init = w.make_init(self.psk, self.private, self.config)
        self.protection = None
        self.clear_media()
        self.clear_reliable()
        self.next_frame = self.expected = 1
        self.status = "handshake"
        self.init_attempts = 0
        self.init_at = 0
        self.event("handshake_start")

    def receive(self, data: bytes, addr: Address) -> None:
        now = time.monotonic()
        try:
            w.require(bool(data), "empty datagram")
            if data[0] == 128 and self.host:
                self.accept_init(data, addr, now)
                return
            if data[0] == 129 and not self.host:
                self.accept_response(data, now)
                return
            if data[0] == 130 and not self.host:
                if len(data) == 21 and self.protection and int.from_bytes(data[1:5], "big") == self.protection.session and hmac.compare_digest(data[5:], self.token):
                    self.stats["session_unknown"] += 1
                    self.on_reset()
                    self.start()
                return
            if self.host and len(data) >= 32 and data[0] < 128 and (self.protection is None or int.from_bytes(data[4:8], "big") != self.protection.session):
                if now - getattr(self, "last_reset", 0) >= 0.05:
                    self.last_reset = now
                    session = data[4:8]
                    self.raw(b"\x82" + session + hmac.digest(self.reset_key, session, "sha256")[:16], addr)
                return
            w.require(self.protection is not None, "no session")
            number, timestamp, body, newest = self.protection.open(data)
            if self.host and self.destination != addr:
                w.require(newest, "old packet cannot rebind")
                self.destination = addr
                self.stats["rebinds"] += 1
            self.stats["datagrams_received"] += 1
            self.last_rx = now
            if self.host and self.status == "parked":
                self.activate_resume()
            if self.status not in ("active", "resuming"):
                return
            chunks = w.items(body, strict=False)
            self.arrivals[number] = w.us()
            self.feedback_needed |= any(kind not in (w.FEEDBACK, w.PONG) for kind, _ in chunks)
            if len(self.arrivals) >= 100:
                self.send_feedback()
            for kind, chunk in chunks:
                try:
                    self.chunk(kind, chunk, timestamp, now)
                except (w.Invalid, struct.error) as exc:
                    self.stats["invalid_chunks"] += 1
                    self.event("invalid_chunk", kind=kind, reason=str(exc))
        except (w.Invalid, InvalidTag, ValueError, struct.error) as exc:
            self.stats["replays" if str(exc) == "replay" else "invalid_packets"] += 1

    def accept_init(self, data: bytes, addr: Address, now: float) -> None:
        config, fields = w.open_init(self.psk, data)
        digest = hashlib.sha256(data).digest()
        if digest in self.cache and now - self.cache[digest][0] < 60:
            self.raw(self.cache[digest][1], addr)
            self.stats["cached_responses"] += 1
            return
        w.require(abs(int(time.time()) - int.from_bytes(fields[2], "big")) <= 30, "stale INIT")
        w.require(fields[4] == w.STREAMS, "demo supports one forward video stream")
        self.config = config
        session = int.from_bytes(os.urandom(4), "big") or 1
        private = X25519PrivateKey.generate()
        prefix = b"\x81\0" + struct.pack("!I", session) + private.public_key().public_bytes_raw()
        response, client, host = w.traffic_keys(self.psk, private, data[12:44], data, prefix)
        self.token = hmac.digest(self.reset_key, struct.pack("!I", session), "sha256")[:16]
        payload = w.parameters(config, token=self.token, grace=self.grace)
        packet = prefix + AESGCM(response[:16]).encrypt(response[16:], payload, prefix)
        w.require(len(packet) <= len(data), "amplifying RESPONSE")
        self.protection = w.Protection(session, host, client)
        self.destination = addr
        self.clear_media()
        self.clear_reliable()
        self.next_frame = 1
        self.force_idr = True
        self.status = "active"
        self.last_rx = now
        self.cache[digest] = (now, packet)
        while len(self.cache) > 1024:
            self.cache.popitem(last=False)
        self.raw(packet)
        self.on_config(self.config)
        self.stats["handshakes"] += 1
        self.event("established", session=session)

    def accept_response(self, data: bytes, now: float) -> None:
        w.require(self.status == "handshake" and 54 <= len(data) <= len(self.init) and data[:2] == b"\x81\0", "unexpected RESPONSE")
        response, client, host = w.traffic_keys(self.psk, self.private, data[6:38], self.init, data[:38])
        payload = AESGCM(response[:16]).decrypt(response[16:], data[38:], data[:38])
        config, fields = w.parse_parameters(payload, True)
        w.require(config.mds <= self.config.mds and fields[3] == b"\0\0" and fields[4] == w.STREAMS, "unsupported acceptance")
        session = int.from_bytes(data[2:6], "big")
        w.require(session != 0, "zero session")
        self.protection = w.Protection(session, client, host)
        self.config, self.token = config, fields[8]
        self.status = "active"
        self.last_rx = now
        self.stats["handshakes"] += 1
        self.event("established", session=session)

    def clear_media(self) -> None:
        self.assemblies.clear()
        self.ready.clear()
        self.missing.clear()
        self.store.clear()
        self.store_bytes = 0
        self.retransmit_at.clear()
        self.media_queue.clear()
        self.repair_queue.clear()
        self.completed.clear()
        self.refresh_pending = None
        self.refresh_seen.clear()
        self.awaiting_idr = True
        self.last_decoded = 0

    def clear_reliable(self) -> None:
        self.reliable_tx = self.reliable_rx = 0
        self.reliable_pending.clear()
        self.reliable_ready.clear()
        self.reliable_parts.clear()
        self.acks.clear()
        self.arrivals.clear()

    def park(self) -> None:
        if not self.host:
            self.send(w.PARK, b"")
        self.status = "parked"
        self.parked_at = time.monotonic()
        self.clear_media()
        self.clear_reliable()
        self.event("parked")

    def resume(self) -> None:
        self.clear_media()
        self.clear_reliable()
        self.on_reset()
        self.status = "resuming"
        self.resume_attempts = 0
        self.resume_at = 0
        self.last_rx = time.monotonic()
        self.event("resume_start")

    def activate_resume(self) -> None:
        self.clear_media()
        self.clear_reliable()
        self.status = "active"
        self.force_idr = True
        self.reliable(struct.pack("!BIB", 3, 0, 0) + self.config.encode(flags=1))
        self.stats["resumes"] += 1
        self.event("resumed")

    def reliable(self, message: bytes) -> None:
        w.require(len(self.reliable_pending) < 256, "reliable send bound")
        sequence = self.reliable_tx
        self.reliable_tx = (sequence + 1) & w.MASK
        w.require(len(message) <= self.config.mds - 44, "demo control must fit one reliable segment")
        body = struct.pack("!BIHH", 0, sequence, 0, 1) + message
        interval = max(1.5 * self.rtt, 0.02)
        self.reliable_pending[sequence] = (body, time.monotonic() + interval, interval)
        self.send(w.RELIABLE, body)

    def reconfigure(self, fields: bytes) -> None:
        self.request_id += 1
        self.reliable(struct.pack("!BIB", 1, self.request_id, 0) + fields)

    def control(self, data: bytes) -> None:
        w.require(len(data) >= 6, "control header")
        kind, request, stream = struct.unpack("!BIB", data[:6])
        w.require(stream in (0, 1), "control scope")
        fields = dict(w.items(data[6:]))
        if kind == 1 and self.host:
            config = replace(self.config)
            rejected = 0
            for number, value in fields.items():
                if number not in range(1, 7):
                    continue
                try:
                    values = dict(w.items(config.encode()))
                    values[number] = value
                    candidate = w.Config.decode(b"".join(w.tlv(k, v) for k, v in values.items()))
                    # HDR and live rate changes require a codec adapter beyond this demo.
                    w.require(candidate.hdr == 0 and candidate.bitrate == config.bitrate, "codec cannot apply change live")
                    w.require(candidate.width <= 3840 and candidate.height <= 2160 and candidate.width % 2 == 0 and candidate.height % 2 == 0, "demo resolution bound")
                    config = candidate
                except w.Invalid:
                    rejected |= 1 << (number - 1)
            if config != self.config:
                resolution = (config.width, config.height) != (self.config.width, self.config.height)
                config.generation += 1
                self.config = config
                self.force_idr |= resolution
                self.on_config(config)
            self.reliable(struct.pack("!BIB", 2, request, stream) + self.config.encode(rejected=rejected))
            self.event("reconfigured", generation=self.config.generation, rejected=rejected)
        elif kind in (2, 3) and not self.host:
            self.config = w.Config.decode(data[6:])
            if kind == 3 and fields.get(8, b"\0")[0] & 1:
                self.status = "active"
                self.stats["resumes"] += 1
                self.event("resume_state")
            else:
                self.event("configuration_received", generation=self.config.generation)
        else:
            self.stats["unknown_control"] += 1

    def chunk(self, kind: int, body: bytes, timestamp: int, now: float) -> None:
        if kind == w.MEDIA:
            w.require(not self.host, "wrong media direction")
            self.receive_media(body, now)
        elif kind == w.RELIABLE:
            w.require(len(body) >= 9, "reliable header")
            stream, sequence, index, count = struct.unpack("!BIHH", body[:9])
            w.require(stream == 0 and 0 < count <= 256 and index < count, "reliable dimensions")
            if w.difference(sequence, self.reliable_rx) < 0:
                self.acks.add((0, sequence))
                return
            w.require(w.difference(sequence, self.reliable_rx) < 256, "reliable receive bound")
            old_count, parts = self.reliable_parts.setdefault(sequence, (count, {}))
            w.require(count == old_count, "reliable count changed")
            parts[index] = body[9:]
            w.require(sum(map(len, parts.values())) <= 1_048_576, "reliable byte bound")
            if len(parts) == count:
                self.reliable_ready[sequence] = b"".join(parts[i] for i in range(count))
                del self.reliable_parts[sequence]
                self.acks.add((0, sequence))
            while self.reliable_rx in self.reliable_ready:
                message = self.reliable_ready.pop(self.reliable_rx)
                self.reliable_rx = (self.reliable_rx + 1) & w.MASK
                self.control(message)
        elif kind == w.FEEDBACK:
            received, count, acks = w.parse_feedback(body)
            self.loss_received += len(received)
            self.loss_total += count
            for stream, sequence in acks:
                if stream == 0:
                    self.reliable_pending.pop(sequence, None)
            if received:
                sequence, arrival = received[-1]
                if sequence in self.sent:
                    sample = now - self.sent[sequence] - w.difference(timestamp, arrival) / 1e6
                    if 0 < sample < 5:
                        self.rtt = self.rtt * 0.875 + sample * 0.125
                        self.stats["rtt_samples"] += 1
        elif kind == w.NACK:
            w.require(self.host and len(body) >= 1 and body[0] == 1 and (len(body) - 1) % 8 == 0, "NACK body")
            for offset in range(1, len(body), 8):
                frame_id, first, count = struct.unpack("!IHH", body[offset:offset + 8])
                stored = self.store.get(frame_id)
                if stored is None:
                    self.stats["nack_store_miss"] += 1
                    continue
                fragments, submitted = stored
                if now - submitted >= self.deadline:
                    continue
                end = min(len(fragments), first + count) if count else len(fragments)
                for index in range(first if count else 0, end):
                    key = frame_id, index
                    if now - self.retransmit_at.get(key, 0) < self.rtt / 2:
                        continue
                    self.retransmit_at[key] = now
                    part = fragments[index]
                    self.repair_queue.append((part[:1] + bytes([part[1] | 2]) + part[2:], submitted + self.deadline))
                    self.stats["retransmissions"] += 1
        elif kind == w.REFRESH:
            w.require(self.host and len(body) == 15, "refresh size/direction")
            stream, reason, preferred, _, _, request = struct.unpack("!BBBIII", body)
            w.require(stream == 1 and reason <= 2 and preferred <= 1, "refresh values")
            if request not in self.refresh_seen:
                self.refresh_seen.append(request)
                self.force_idr = True
                self.stats["refreshes"] += 1
                self.event("refresh_requested", request=request)
        elif kind == w.PING:
            w.require(len(body) == 4, "PING size")
            self.send(w.PONG, body + struct.pack("!I", 0))
        elif kind == w.PONG:
            w.require(len(body) == 8, "PONG size")
            ident, hold = struct.unpack("!II", body)
            sent = self.pings.pop(ident, None)
            if sent is not None:
                self.rtt = max(0.0001, 0.875 * self.rtt + 0.125 * max(0, now - sent - hold / 1e6))
        elif kind == w.PARK:
            w.require(not body, "PARK size")
            if self.host:
                self.park()
        elif kind == w.RESUME:
            w.require(len(body) == 1, "RESUME size")
            if self.host:
                self.stats["resume_decoder_lost" if body[0] & 1 else "resume_decoder_kept"] += 1
        elif kind == w.CLOSE:
            w.require(len(body) == 2, "CLOSE size")
            self.status = "closed"
            self.clear_media()
            self.protection = None
        else:
            self.stats["unknown_chunks"] += 1

    @property
    def deadline(self) -> float:
        return 3 / self.config.fps

    def submit(self, frame: w.Frame) -> int:
        w.require(self.host and self.status == "active", "inactive sender")
        now = time.monotonic()
        frame_id = self.next_frame
        parts = w.fragments(frame_id, frame.encode(), self.config.mds)
        size = sum(map(len, parts))
        w.require(len(self.media_queue) + len(self.repair_queue) + len(parts) <= 16384, "pacer queue bound")
        self.next_frame = w.successor(frame_id)
        self.store[frame_id] = (parts, now)
        self.store_bytes += size
        while self.store_bytes > 16 * 1024 * 1024:
            _, (removed, _) = self.store.popitem(last=False)
            self.store_bytes -= sum(map(len, removed))
        self.media_queue.extend((part, now + self.deadline) for part in parts)
        self.stats["frames_submitted"] += 1
        self.stats["idr_submitted"] += frame.kind == 0
        return frame_id

    def receive_media(self, body: bytes, now: float) -> None:
        frame_id, index, count, stride, payload = w.fragment(body)
        if frame_id in self.completed or (self.last_decoded and w.difference(frame_id, self.last_decoded) <= 0):
            self.stats["late_fragments"] += 1
            return
        if self.awaiting_idr and body[1] & 1:
            # Resume has no first-frame-ID field; bootstrap only from the recovery IDR.
            self.expected = frame_id
        distance = w.difference(frame_id, self.expected)
        w.require(distance <= 128, "media receive window")
        ident = self.expected
        for _ in range(max(0, distance)):
            if ident not in self.ready and ident not in self.assemblies:
                self.missing.setdefault(ident, (now, 0))
            ident = w.successor(ident)
        assembly = self.assemblies.get(frame_id)
        if assembly is None:
            w.require(len(self.assemblies) < 128 and sum(a.count * a.stride for a in self.assemblies.values()) + count * stride <= 32 * 1024 * 1024, "reassembly memory bound")
            assembly = Assembly(count, stride, now, now)
            self.assemblies[frame_id] = assembly
            self.missing.pop(frame_id, None)
        w.require((assembly.count, assembly.stride) == (count, stride), "inconsistent fragment")
        if index in assembly.parts:
            self.stats["duplicate_fragments"] += 1
            return
        assembly.parts[index] = payload
        assembly.last = now
        if len(assembly.parts) == count:
            self.completed.append(frame_id)
            del self.assemblies[frame_id]
            frame = w.Frame.decode(b"".join(assembly.parts[i] for i in range(count)))
            w.require(len(self.ready) < 128, "hold queue bound")
            self.ready[frame_id] = (frame, assembly.started)
            self.drain(now)

    def drain(self, now: float) -> None:
        while self.expected in self.ready:
            frame_id = self.expected
            frame, arrival = self.ready.pop(frame_id)
            self.expected = w.successor(frame_id)
            valid = frame.kind == 0 or (not self.awaiting_idr and frame.reference == 1 and w.successor(self.last_decoded) == frame_id)
            if not valid:
                self.stats["gated_frames"] += 1
                self.request_refresh(frame_id)
                continue
            if self.on_frame(frame_id, frame, arrival):
                self.last_decoded = frame_id
                self.awaiting_idr = False
                self.refresh_pending = None
                self.stats["frames_decoded"] += 1
                if frame.kind == 0:
                    self.event("idr_decoded", frame_id=frame_id)
            else:
                self.stats["decode_errors"] += 1
                self.awaiting_idr = True
                self.request_refresh(frame_id, reset=True)
        if self.awaiting_idr:
            candidates = [ident for ident, (frame, _) in self.ready.items() if frame.kind == 0]
            if candidates:
                self.expected = min(candidates, key=lambda ident: w.difference(ident, self.expected))
                self.drain(now)

    def request_refresh(self, lost: int, reset: bool = False) -> None:
        self.awaiting_idr = True
        if self.refresh_pending is None or reset:
            self.request_id += 1
            now = time.monotonic()
            self.refresh_pending = (self.request_id, lost, int(reset), now, 0)
            self.event("recovery_start", request=self.request_id, lost=lost)

    def reset_decoder(self) -> None:
        self.on_reset()
        self.last_decoded = 0
        self.request_refresh(0, reset=True)

    def send_feedback(self) -> None:
        numbers = sorted(self.arrivals)
        # Bound by both received count and sequence span, leaving room for explicit ACKs.
        while numbers or self.acks:
            base = numbers[0] if numbers else 0
            selected = [number for number in numbers if number - base < 64][:64]
            acks = sorted(self.acks)[:8]
            self.send(w.FEEDBACK, w.feedback({number: self.arrivals[number] for number in selected}, acks))
            for number in selected:
                del self.arrivals[number]
            self.acks.difference_update(acks)
            numbers = numbers[len(selected):]
        self.last_feedback = time.monotonic()
        self.feedback_needed = False

    def tick(self, now: float) -> None:
        if self.status == "handshake":
            if now >= self.init_at:
                w.require(self.init_attempts < 8, "handshake timed out")
                self.raw(self.init)
                self.init_at = now + min(0.1 * 2**self.init_attempts, 2)
                self.init_attempts += 1
            return
        if self.status == "parked":
            if self.host and now - self.parked_at >= self.grace:
                self.expired_session = self.protection.session if self.protection else None
                self.protection = None
                self.status = "expired"
                self.event("expired")
            return
        if self.status not in ("active", "resuming"):
            return
        if self.status == "resuming" and now >= self.resume_at:
            self.send(w.RESUME, b"\1")
            self.resume_at = now + min(0.1 * 2**self.resume_attempts, 2)
            self.resume_attempts += 1
        if now - self.last_rx > 2:
            if self.host:
                self.park()
            else:
                # Experiment policy: an unverifiable reset after host restart needs a liveness timeout.
                self.event("liveness_rehandshake")
                self.on_reset()
                self.start()
            return
        if (self.feedback_needed or self.acks) and now - self.last_feedback >= 0.025:
            self.send_feedback()
        if now - self.last_ping >= 0.25:
            ident = w.us()
            self.pings[ident] = now
            self.pings = {key: at for key, at in self.pings.items() if now - at < 5}
            self.send(w.PING, struct.pack("!I", ident))
            self.last_ping = now
        for sequence, (body, due, interval) in list(self.reliable_pending.items()):
            if now >= due:
                self.send(w.RELIABLE, body)
                self.reliable_pending[sequence] = body, now + min(interval * 2, 2), min(interval * 2, 2)
                self.stats["reliable_retransmissions"] += 1
        if self.host:
            self.pace(now)
            for frame_id, (parts, submitted) in list(self.store.items()):
                if now - submitted >= 0.5:
                    self.store_bytes -= sum(map(len, parts))
                    del self.store[frame_id]
            self.retransmit_at = {key: at for key, at in self.retransmit_at.items() if key[0] in self.store}
        else:
            self.repair(now)
        if self.host and now - self.loss_at >= 0.5:
            self.loss_windows.append(1 - self.loss_received / self.loss_total if self.loss_total else 0)
            self.loss_received = self.loss_total = 0
            self.loss_at = now
            if len(self.loss_windows) == 4 and all(loss > 0.1 for loss in self.loss_windows) and not self.backstop:
                # The demo reports the trigger, but cannot honestly claim a live x265 bitrate clamp.
                self.stats["backstop_required"] += 1
                self.backstop = True
                self.event("unsupported_backstop", reason="libx265 adapter has no verified live bitrate reconfiguration")

    def pace(self, now: float) -> None:
        backlog = sum(len(part) + 35 for part, deadline in self.media_queue if deadline > now)
        self.pacer_rate = min(250_000_000, max(self.config.bitrate / 8 * 1.25, backlog * self.config.fps))
        self.tokens = min(32 * self.config.mds, self.tokens + (now - self.pacer_at) * self.pacer_rate)
        self.pacer_at = now
        for _ in range(32):
            queue = self.repair_queue if self.repair_queue else self.media_queue
            if not queue:
                return
            body, deadline = queue[0]
            if now >= deadline:
                queue.popleft()
                self.stats["expired_send_fragments"] += 1
                continue
            size = len(body) + 35
            if self.tokens < size:
                return
            self.tokens -= size
            queue.popleft()
            self.send(w.MEDIA, body)

    def repair(self, now: float) -> None:
        reorder = max(0.001, self.rtt / 4)
        retry = max(1.5 * self.rtt, 0.002)
        entries = []
        expired = []
        for frame_id, assembly in list(self.assemblies.items()):
            if now - assembly.started >= self.deadline:
                del self.assemblies[frame_id]
                expired.append(frame_id)
                continue
            # Two intervals cover a full paced frame plus scheduler/burst slack before tail repair.
            ceiling = assembly.count if now - assembly.started >= 2 / self.config.fps and now - assembly.last >= reorder else max(assembly.parts) + 1
            if now - assembly.started >= reorder and now - assembly.nack_at >= retry:
                missing = [index for index in range(ceiling) if index not in assembly.parts]
                for index in missing:
                    entries.append((frame_id, index, 1))
                if missing:
                    assembly.nack_at = now
        for frame_id, (started, last) in list(self.missing.items()):
            if now - started >= self.deadline:
                del self.missing[frame_id]
                expired.append(frame_id)
            elif now - started >= reorder and now - last >= retry:
                entries.append((frame_id, 0, 0))
                self.missing[frame_id] = (started, now)
        for frame_id in expired:
            self.stats["frames_expired"] += 1
            if frame_id == self.expected:
                self.expected = w.successor(frame_id)
            self.request_refresh(frame_id)
        # A complete held frame must not outlive the bounded playout deadline either.
        for frame_id, (_, arrived) in list(self.ready.items()):
            if now - arrived >= self.deadline and frame_id != self.expected:
                del self.ready[frame_id]
                self.stats["held_expired"] += 1
                self.request_refresh(frame_id)
        self.drain(now)
        limit = max(1, (self.config.mds - 36) // 8)
        for offset in range(0, len(entries), limit):
            batch = entries[offset:offset + limit]
            self.send(w.NACK, b"\1" + b"".join(struct.pack("!IHH", *entry) for entry in batch))
            self.stats["nack_entries"] += len(batch)
            self.event("nack", entries=batch)
        if self.refresh_pending:
            request, lost, reason, started, last = self.refresh_pending
            if not self.strict_recovery and now - started > max(self.deadline * 2, self.rtt * 3):
                # Documented experiment policy: a lost/expired recovery needs a NEW request.
                self.request_id += 1
                request, started = self.request_id, now
                self.stats["recovery_restarts"] += 1
            if now - last >= max(self.rtt, 0.01):
                self.send(w.REFRESH, struct.pack("!BBBIII", 1, reason, 1, self.last_decoded, lost, request))
                last = now
                self.stats["refresh_requests"] += 1
            self.refresh_pending = request, lost, reason, started, last
