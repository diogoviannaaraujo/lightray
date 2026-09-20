#!/usr/bin/env python3
"""Check the local Mac baseline targets without trusting plugin exit codes."""
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "Docs/benchmarks")
text = (root / "microbenchmarks.txt").read_text()
if re.search(r"\bfailed\b|\berror:", text, re.IGNORECASE):
    raise SystemExit("Benchmark runner reported a failure")
for name in ("Allocation assertion wire streams stats", "Allocation counter positive control"):
    if name not in text:
        raise SystemExit(f"Missing allocation verification: {name}")
section = text.split("Receive parse place stats steady state", 1)[1]
row = next(line for line in section.splitlines() if "Time (wall clock)" in line)
columns = [value.strip() for value in row.split("│") if value.strip()]
p90 = float(columns[5])
if "(μs)" in columns[0]:
    p90 *= 1000
if p90 >= 250:
    raise SystemExit(f"Receive p90 {p90} ns exceeds the 250 ns target")
for name in ("20", "80", "1000", "reconnect"):
    report = json.loads((root / f"loopback-{name}.json").read_text())
    if report["errors"] or report["authentication_failures"]:
        raise SystemExit(f"Loopback {name} reported errors")
    if report["frames_received"] != report["frames_submitted"]:
        raise SystemExit(f"Loopback {name} did not deliver every submitted frame")
    if name == "1000" and report["udp_received_gbps_including_drain"] < 1:
        raise SystemExit("Protected UDP loopback did not sustain 1 Gbps")
    if name == "reconnect" and (report["old_client_port"] == report["new_client_port"] or report["resumes"] < 1):
        raise SystemExit("Reconnect benchmark did not replace the socket and resume")
print(f"PASS: receive p90={p90:.0f} ns, zero steady-state allocations with positive control, complete loopback delivery, >=1 Gbps protected UDP, socket replacement")
