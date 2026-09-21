"""Seeded, bounded user-space impairment relay over real localhost UDP sockets."""
import asyncio
from collections import Counter
from dataclasses import dataclass
import random
import socket
import sys
import time
from typing import Callable


Address = tuple[str, int]


def udp_socket() -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setblocking(False)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    if sys.platform == "darwin":
        sock.setsockopt(socket.IPPROTO_IP, 28, 1)  # IP_DONTFRAG on an AF_INET socket.
    elif sys.platform.startswith("linux"):
        sock.setsockopt(socket.IPPROTO_IP, 10, 2)  # IP_MTU_DISCOVER / IP_PMTUDISC_DO.
    sock.bind(("127.0.0.1", 0))
    return sock


@dataclass
class Link:
    delay_ms: float = 0
    jitter_ms: float = 0
    loss: float = 0
    reverse_loss: float = 0
    duplicate: float = 0
    reorder: float = 0
    corrupt: float = 0
    mbps: float = 1000
    queue_ms: float = 50
    mtu: int = 9000
    burst: bool = False
    drop_response: bool = False


class Port(asyncio.DatagramProtocol):
    def __init__(self, receive: Callable[[bytes, Address], None]):
        self.receive = receive
        self.transport: asyncio.DatagramTransport | None = None
        self.errors: list[str] = []

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport

    def datagram_received(self, data: bytes, addr: Address) -> None:
        try:
            self.receive(data, addr)
        except Exception as exc:
            # Asyncio otherwise only logs callback failures; preserve them as scenario failures.
            self.errors.append(f"callback {type(exc).__name__}: {exc}")

    def error_received(self, exc: Exception) -> None:
        self.errors.append(str(exc))

    def send(self, data: bytes, addr: Address) -> None:
        if self.transport is None:
            raise RuntimeError("UDP endpoint not open")
        self.transport.sendto(data, addr)

    @property
    def address(self) -> Address:
        if self.transport is None:
            raise RuntimeError("UDP endpoint not open")
        return self.transport.get_extra_info("sockname")

    def close(self) -> None:
        if self.transport is not None:
            self.transport.close()


async def open_port(receive: Callable[[bytes, Address], None]) -> Port:
    port = Port(receive)
    await asyncio.get_running_loop().create_datagram_endpoint(lambda: port, sock=udp_socket())
    return port


class Relay:
    def __init__(self, link: Link, seed: int):
        self.link = link
        self.random = random.Random(seed)
        self.counts: Counter[str] = Counter()
        self.host: Address | None = None
        self.client: Address | None = None
        self.down: Port | None = None
        self.up: Port | None = None
        self.finish = {"down": 0.0, "up": 0.0}
        self.bad = {"down": False, "up": False}
        self.block_until = 0.0
        self.video_block_until = 0.0
        self.drop_down_protected = 0
        self.handles: set[asyncio.TimerHandle] = set()
        self.old_ports: list[Port] = []

    async def open(self) -> None:
        self.down = await open_port(lambda data, addr: self.forward(data, "down"))
        self.up = await open_port(self.from_client)

    def from_client(self, data: bytes, addr: Address) -> None:
        self.client = addr
        self.forward(data, "up")

    async def rebind(self) -> None:
        # A new relay egress socket creates a real source-port change at the host.
        if self.down is None:
            raise RuntimeError("relay not open")
        self.old_ports.append(self.down)
        self.down = await open_port(lambda data, addr: self.forward(data, "down"))
        self.counts["rebinds"] += 1

    def forward(self, data: bytes, direction: str) -> None:
        now = time.monotonic()
        self.counts[f"{direction}_offered"] += 1
        self.counts[f"{direction}_bytes"] += len(data)
        if now < self.block_until or (direction == "down" and now < self.video_block_until and data[0] < 128):
            self.counts["blackout_drops"] += 1
            return
        if direction == "down" and data[:1] == b"\x81" and self.link.drop_response:
            self.link.drop_response = False
            self.counts["response_drops"] += 1
            return
        if direction == "down" and data[0] < 128 and self.drop_down_protected:
            self.drop_down_protected -= 1
            self.counts["targeted_drops"] += 1
            return
        if len(data) > self.link.mtu:
            self.counts["mtu_drops"] += 1
            return
        loss = self.link.loss if direction == "down" else self.link.reverse_loss
        if self.link.burst:
            if self.random.random() < (0.25 if self.bad[direction] else 0.015):
                self.bad[direction] = not self.bad[direction]
            loss = 0.7 if self.bad[direction] else loss
        if self.random.random() < loss:
            self.counts[f"{direction}_loss_drops"] += 1
            return
        duration = len(data) * 8 / (self.link.mbps * 1e6)
        start = max(now, self.finish[direction])
        if start - now > self.link.queue_ms / 1000:
            self.counts["queue_drops"] += 1
            return
        self.finish[direction] = start + duration
        delay = max(0, self.link.delay_ms + self.random.uniform(-self.link.jitter_ms, self.link.jitter_ms)) / 1000
        if self.random.random() < self.link.reorder:
            delay += 0.012
            self.counts["reordered"] += 1
        if self.random.random() < self.link.corrupt and data[0] < 128:
            data = data[:-1] + bytes([data[-1] ^ 1])
            self.counts["corrupted"] += 1
        self.schedule(data, direction, self.finish[direction] + delay - now)
        if self.random.random() < self.link.duplicate:
            self.schedule(data, direction, self.finish[direction] + delay - now + 0.002)
            self.counts["duplicated"] += 1

    def schedule(self, data: bytes, direction: str, delay: float) -> None:
        if len(self.handles) >= 8192:
            self.counts["relay_capacity_drops"] += 1
            return
        def deliver() -> None:
            self.handles.discard(handle)
            destination = self.client if direction == "down" else self.host
            port = self.up if direction == "down" else self.down
            if destination is not None and port is not None:
                port.send(data, destination)
                self.counts[f"{direction}_delivered"] += 1
        handle = asyncio.get_running_loop().call_later(max(0, delay), deliver)
        self.handles.add(handle)

    def close(self) -> None:
        for handle in self.handles:
            handle.cancel()
        self.handles.clear()
        for port in [self.down, self.up, *self.old_ports]:
            if port:
                port.close()
