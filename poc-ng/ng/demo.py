"""Real-time HEVC -> encrypted UDP -> impairment relay -> decoded-pixel validation."""
import argparse
import asyncio
from dataclasses import asdict, dataclass, replace
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import struct
import sys
import time

import av
import cryptography

from . import wire as w
from .media import Decoder, Encoder, pixel_hash
from .network import Link, Relay
from .session import Peer


@dataclass
class Scenario:
    name: str
    link: Link
    action: str = ""
    minimum_delivery: float = 0.2


SCENARIOS = [
    Scenario("clean", Link(), minimum_delivery=0.99),
    Scenario("lan", Link(delay_ms=1), minimum_delivery=0.99),
    Scenario("wan", Link(delay_ms=20, jitter_ms=3), minimum_delivery=0.95),
    Scenario("long_rtt", Link(delay_ms=60, jitter_ms=5), minimum_delivery=0.9),
    Scenario("random_loss", Link(delay_ms=3, loss=0.01, reverse_loss=0.01), minimum_delivery=0.65),
    Scenario("burst_loss", Link(delay_ms=3, burst=True)),
    Scenario("reordering", Link(delay_ms=2, jitter_ms=2, reorder=0.1, duplicate=0.05), minimum_delivery=0.8),
    Scenario("corruption", Link(delay_ms=2, corrupt=0.01), minimum_delivery=0.6),
    Scenario("constrained", Link(delay_ms=5, mbps=2, queue_ms=30)),
    Scenario("reverse_loss", Link(delay_ms=5, reverse_loss=0.15), minimum_delivery=0.8),
    Scenario("lost_response", Link(delay_ms=2, drop_response=True), minimum_delivery=0.99),
    Scenario("blackout", Link(delay_ms=3), "blackout"),
    Scenario("lost_recovery", Link(delay_ms=2), "lost_recovery"),
    Scenario("decoder_reset", Link(delay_ms=2), "decoder_reset", 0.8),
    Scenario("rebind", Link(delay_ms=2), "rebind", 0.99),
    Scenario("park_resume", Link(delay_ms=2, reverse_loss=0.02), "park_resume", 0.8),
    Scenario("resume_state_loss", Link(delay_ms=2), "resume_state_loss", 0.8),
    Scenario("expiry", Link(delay_ms=2), "expiry", 0.8),
    Scenario("host_restart", Link(delay_ms=2), "host_restart", 0.6),
    Scenario("mtu_change", Link(delay_ms=2), "mtu_change", 0.8),
    Scenario("resolution_change", Link(delay_ms=2), "resolution_change", 0.8),
    Scenario("framerate_change", Link(delay_ms=2), "framerate_change", 0.8),
]


def distribution(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "p50": None, "p95": None, "p99": None, "max": None}
    ordered = sorted(values)
    return {"count": len(values), "p50": round(statistics.median(ordered), 3), "p95": round(ordered[min(len(ordered) - 1, int((len(ordered) - 1) * .95))], 3), "p99": round(ordered[min(len(ordered) - 1, int((len(ordered) - 1) * .99))], 3), "max": round(ordered[-1], 3)}


def make_sample(path: Path, width: int, height: int, fps: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with av.open(f"testsrc2=size={width}x{height}:rate={fps}", format="lavfi") as source, av.open(str(path), "w") as output:
        stream = output.add_stream("libx265", rate=fps)
        stream.width, stream.height, stream.pix_fmt = width, height, "yuv420p"
        stream.options = {"preset": "ultrafast", "tune": "zerolatency", "x265-params": "bframes=0:keyint=30:log-level=error:pools=none"}
        for index, frame in enumerate(source.decode(video=0)):
            if index >= fps * 3:
                break
            for packet in stream.encode(frame):
                output.mux(packet)
        for packet in stream.encode():
            output.mux(packet)


async def run_scenario(scenario: Scenario, input_path: Path, config: w.Config, seconds: float, seed: int, output: Path, strict_recovery: bool = False) -> dict[str, object]:
    psk = os.urandom(32)
    host, client = Peer(True, psk, config), Peer(False, psk, config, strict_recovery=strict_recovery)
    relay = Relay(replace(scenario.link), seed)
    await host.open()
    await client.open()
    await relay.open()
    relay.host, relay.client = host.port.address, client.port.address
    client.destination = relay.up.address
    encoder = Encoder(config, input_path)
    decoder = Decoder()
    rows: dict[tuple[int, int], dict[str, object]] = {}
    decoded_times: list[float] = []
    mismatches: list[dict[str, object]] = []
    errors: list[str] = []
    action_events: list[dict[str, object]] = []
    needs_encoder = False
    received_file = (output / f"{scenario.name}.h265").open("wb")
    last_client_session = None

    def reset_decoder() -> None:
        nonlocal decoder
        decoder = Decoder()

    def configure(new: w.Config) -> None:
        nonlocal needs_encoder
        needs_encoder = (new.width, new.height) != (encoder.config.width, encoder.config.height)
        if not needs_encoder:
            encoder.config = replace(new)

    def received(ident: int, frame: w.Frame, first: float) -> bool:
        nonlocal decoder, last_client_session
        start = time.monotonic()
        session = client.protection.session
        row = rows.get((session, ident))
        if row is None:
            errors.append(f"received unknown frame {ident}")
            return False
        if row.get("decoded") is not None:
            errors.append(f"duplicate delivery {ident}")
            return False
        try:
            if frame.kind == 0 and (last_client_session != session or row["width"] != getattr(received, "width", 0)):
                decoder = Decoder()
            picture = decoder.decode(frame)
            end = time.monotonic()
            actual = pixel_hash(picture)
        except (av.error.FFmpegError, w.Invalid) as exc:
            errors.append(f"decode: {exc}")
            return False
        if actual != row["expected_hash"]:
            mismatches.append({"frame": ident, "session": session})
        row.update(decoded=end, latency_ms=(end - row["capture"]) * 1000, transport_ms=(start - row["submitted"]) * 1000, decode_ms=(end - start) * 1000, reassembly_ms=(start - first) * 1000, pixel_match=actual == row["expected_hash"])
        decoded_times.append(end)
        received.width = picture.width
        last_client_session = session
        received_file.write(b"".join(b"\0\0\0\1" + nal for nal in w.nals(frame.codec) + w.nals(frame.payload)))
        return True

    host.on_config = configure
    client.on_frame, client.on_reset = received, reset_decoder
    client.start()
    started = time.monotonic()
    stream_start = None
    next_capture = started
    action_done = False
    resume_due = None
    recovery_blocked = False
    scheduled_skips = 0
    try:
        while True:
            now = time.monotonic()
            host.tick(now)
            client.tick(now)
            if stream_start is None and client.status == "active":
                stream_start = now
                next_capture = now
            if stream_start is None:
                if now - started > 8:
                    raise RuntimeError("handshake did not complete")
                await asyncio.sleep(.001)
                continue
            elapsed = now - stream_start
            if elapsed >= seconds + .6:
                break
            if not action_done and elapsed >= seconds * .35 and scenario.action:
                action_done = True
                action_events.append({"event": scenario.action, "time": now})
                action = scenario.action
                if action == "blackout":
                    relay.block_until = now + .25
                elif action == "lost_recovery":
                    client.reset_decoder()
                elif action == "decoder_reset":
                    client.reset_decoder()
                elif action == "rebind":
                    await client.rebind()
                    relay.client = client.port.address
                    await relay.rebind()
                    client.send(w.PING, struct.pack("!I", w.us()))
                elif action in ("park_resume", "resume_state_loss", "expiry"):
                    if action == "expiry":
                        host.grace = .15
                    client.park()
                    resume_due = now + .3
                elif action == "host_restart":
                    # Replace all host session/reset cryptographic state, as on a process restart.
                    host.protection = None
                    host.reset_key = os.urandom(32)
                    host.status = "expired"
                    host.clear_media()
                    host.clear_reliable()
                    host.cache.clear()
                elif action == "mtu_change":
                    relay.link.mtu = 800
                    client.reconfigure(w.tlv(6, struct.pack("!H", 800)))
                elif action == "resolution_change":
                    client.reconfigure(w.tlv(3, struct.pack("!HH", 320, 180)))
                elif action == "framerate_change":
                    client.reconfigure(w.tlv(4, struct.pack("!H", max(10, config.fps // 2))))
            if scenario.action == "lost_recovery" and action_done and host.stats["refreshes"] and not recovery_blocked:
                relay.video_block_until = now + .25
                recovery_blocked = True
            if resume_due is not None and now >= resume_due:
                await client.rebind()
                relay.client = client.port.address
                await relay.rebind()
                if scenario.action == "resume_state_loss":
                    relay.drop_down_protected = 1
                client.resume()
                action_events.append({"event": "resume", "time": now})
                resume_due = None
            if needs_encoder:
                encoder.close()
                encoder = Encoder(replace(host.config), input_path)
                needs_encoder = False
            if elapsed < seconds and host.status == "active" and now >= next_capture:
                interval = 1 / host.config.fps
                behind = max(0, int((now - next_capture) / interval))
                scheduled_skips += behind
                next_capture += (behind + 1) * interval
                force = host.force_idr
                host.force_idr = False
                encoding_session = host.protection.session
                frame, expected, timing = await asyncio.to_thread(encoder.encode, force)
                if host.status != "active" or host.protection is None or host.protection.session != encoding_session:
                    host.stats["encode_cancelled_on_transition"] += 1
                    continue
                ident = host.submit(frame)
                session = host.protection.session
                rows[session, ident] = {"frame": ident, "session": session, "idr": frame.kind == 0, "generation": frame.generation, "width": host.config.width, "height": host.config.height, "bytes": len(frame.encode()), "expected_hash": expected, **timing, "submitted": time.monotonic(), "decoded": None}
            if host.status != "active":
                next_capture = time.monotonic()
            await asyncio.sleep(.001)
    finally:
        received_file.close()
        encoder.close()
        relay.close()
        host.port.close()
        client.port.close()
    try:
        with av.open(str(output / f"{scenario.name}.h265"), format="hevc") as replay:
            replayed = sum(1 for _ in replay.decode(video=0))
        if replayed != len(decoded_times):
            errors.append(f"saved HEVC replay decoded {replayed}, expected {len(decoded_times)}")
    except av.error.FFmpegError as exc:
        errors.append(f"saved HEVC replay failed: {exc}")
    all_rows = list(rows.values())
    delivered = [row for row in all_rows if row["decoded"] is not None]
    ratio = len(delivered) / max(1, len(all_rows))
    failures = list(errors)
    if mismatches:
        failures.append(f"{len(mismatches)} decoded pixel mismatches")
    if ratio < scenario.minimum_delivery:
        failures.append(f"delivery {ratio:.1%} below scenario floor {scenario.minimum_delivery:.1%}")
    if not decoded_times or decoded_times[-1] < stream_start + seconds - .5:
        failures.append("stream did not recover near the end")
    if scenario.name in ("clean", "lan", "lost_response") and client.stats["nack_entries"]:
        failures.append("lossless link generated NACKs")
    if scenario.action == "rebind" and host.stats["idr_submitted"] != 1:
        failures.append("active rebind unexpectedly forced IDR")
    if scenario.action in ("park_resume", "resume_state_loss") and not (host.stats["resumes"] and client.stats["resumes"]):
        failures.append("resume did not complete")
    if scenario.action in ("expiry", "host_restart") and client.stats["handshakes"] != 2:
        failures.append("session loss did not establish a new session")
    if scenario.action == "resume_state_loss" and not host.stats["reliable_retransmissions"]:
        failures.append("lost resume STATE was not retransmitted")
    if scenario.action == "framerate_change" and host.stats["idr_submitted"] != 1:
        failures.append("framerate change unexpectedly forced IDR")
    if scenario.link.drop_response and host.stats["cached_responses"] < 1:
        failures.append("lost RESPONSE was not recovered through the INIT cache")
    for port in [host.port, client.port, relay.up, relay.down, *relay.old_ports]:
        failures.extend(port.errors)
    gaps = [(right - left) * 1000 for left, right in zip(decoded_times, decoded_times[1:])]
    terminal_no_output = max(0, (stream_start + seconds - decoded_times[-1]) * 1000) if decoded_times else seconds * 1000
    recovery_events = []
    for event in action_events:
        future = [at for at in decoded_times if at >= event["time"]]
        recovery_events.append({"event": event["event"], "next_decoded_ms": round((future[0] - event["time"]) * 1000, 3) if future else None})
    result = {"scenario": scenario.name, "seed": seed, "seconds": seconds, "network": asdict(scenario.link), "frames_sent": len(all_rows), "frames_decoded": len(delivered), "delivery_ratio": round(ratio, 5), "pixel_mismatches": len(mismatches), "scheduler_skipped_captures": scheduled_skips, "submitted_fps": round(len(all_rows) / seconds, 3), "latency_ms": distribution([row["latency_ms"] for row in delivered]), "encode_ms": distribution([row["encode_ms"] for row in all_rows]), "transport_ms": distribution([row["transport_ms"] for row in delivered]), "decode_ms": distribution([row["decode_ms"] for row in delivered]), "inter_decoded_gap_ms": distribution(gaps), "terminal_no_output_ms": round(terminal_no_output, 3), "estimated_rtt_ms": round(host.rtt * 1000, 3), "host": dict(host.stats), "client": dict(client.stats), "relay": dict(relay.counts), "actions": recovery_events, "failures": failures, "passed": not failures}
    (output / f"{scenario.name}.frames.json").write_text(json.dumps(all_rows, indent=2) + "\n")
    (output / f"{scenario.name}.events.json").write_text(json.dumps({"host": host.events, "client": client.events, "actions": action_events}, indent=2) + "\n")
    return result


def report_markdown(report: dict[str, object]) -> str:
    lines = ["# HEVC end-to-end results", "", "Real UDP on localhost with a seeded user-space impairment relay; software HEVC encode and decode through PyAV/FFmpeg.", "Capture means submission of a decoded sample picture to the live encoder; latency ends at decoded output, before display.", "Both endpoints use the same machine's monotonic clock; these measurements do not establish one-way latency on unsynchronized remote machines.", "", "| Scenario | Decoded / sent | p50 ms | p95 ms | p99 ms | Max decode gap ms | Pixel errors | Result |", "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for row in report["results"]:
        latency = row["latency_ms"]
        lines.append(f"| {row['scenario']} | {row['frames_decoded']} / {row['frames_sent']} | {latency['p50']} | {latency['p95']} | {latency['p99']} | {row['inter_decoded_gap_ms']['max']} | {row['pixel_mismatches']} | {'PASS' if row['passed'] else 'FAIL'} |")
    lines += ["", "Failures are preserved, not excluded from the report.", "The maximum decode gap includes intentional parks and network outages.", "This is a protocol experiment, not a production throughput benchmark or full v0 conformance claim.", ""]
    return "\n".join(lines)


async def run(args: argparse.Namespace) -> int:
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    input_path = args.input.resolve() if args.input else output / "sample-h265.mp4"
    if not args.input:
        make_sample(input_path, args.width, args.height, args.fps)
    selected = args.scenarios.split(",") if args.scenarios != "all" else [scenario.name for scenario in SCENARIOS]
    unknown = set(selected) - {scenario.name for scenario in SCENARIOS}
    if unknown:
        raise ValueError(f"unknown scenarios: {sorted(unknown)}")
    config = w.Config(width=args.width, height=args.height, fps=args.fps, bitrate=args.bitrate)
    results = []
    for scenario in SCENARIOS:
        if scenario.name not in selected:
            continue
        print(f"Running {scenario.name} ...", flush=True)
        result = await run_scenario(scenario, input_path, config, args.seconds, args.seed, output, args.strict_recovery)
        results.append(result)
        print(f"  {'PASS' if result['passed'] else 'FAIL'}: {result['frames_decoded']}/{result['frames_sent']} frames, p95 {result['latency_ms']['p95']} ms; {result['failures']}", flush=True)
        report = {"environment": {"python": sys.version.split()[0], "platform": platform.platform(), "av": av.__version__, "cryptography": cryptography.__version__, "ffmpeg_libraries": av.library_versions}, "config": asdict(config), "input": {"name": input_path.name, "sha256": hashlib.sha256(input_path.read_bytes()).hexdigest()}, "strict_recovery": args.strict_recovery, "results": results}
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        (output / "summary.md").write_text(report_markdown(report))
    return int(any(not result["passed"] for result in results))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=lambda prog: argparse.RawTextHelpFormatter(prog, width=10000))
    parser.add_argument("--input", type=Path, help="Optional local video; PyAV decodes it and the demo encodes live HEVC for recovery")
    parser.add_argument("--output", type=Path, default=Path("artifacts/latest"))
    parser.add_argument("--scenarios", default="all", help="Comma-separated scenario names, or all")
    parser.add_argument("--seconds", type=float, default=6)
    parser.add_argument("--seed", type=int, default=20260921)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=360)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--bitrate", type=int, default=1_000_000)
    parser.add_argument("--strict-recovery", action="store_true", help="Keep the same refresh ID indefinitely, literally following the current spec")
    args = parser.parse_args()
    if args.seconds < 3 or args.width < 16 or args.height < 16 or args.width % 2 or args.height % 2 or not 1 <= args.fps <= 240 or not 100_000 <= args.bitrate <= 500_000_000:
        parser.error("need >=3 seconds, even dimensions >=16, fps 1..240 and bitrate 100000..500000000")
    raise SystemExit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
