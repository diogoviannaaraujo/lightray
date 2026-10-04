#!/usr/bin/env python3
"""Reproducible corpus validation and read-only Windows inventory; no extra Python dependencies."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs/windows/evidence/foundation/hevc-corpus.json"


def verify_corpus(root=ROOT, manifest=MANIFEST):
    data = json.loads(manifest.read_text())
    checked = []
    paths = set()
    for item in data["files"]:
        path = (root / item["path"]).resolve()
        if not path.is_relative_to(root.resolve()):
            raise ValueError("corpus path escapes the checkout")
        if path in paths:
            raise ValueError("duplicate corpus path")
        paths.add(path)
        payload = path.read_bytes()
        if len(payload) != item["bytes"] or hashlib.sha256(payload).hexdigest() != item["sha256"]:
            raise ValueError("corpus checksum mismatch: " + item["path"])
        checked.append(item)
    if data.get("kind") in ("synthetic-videotoolbox", "synthetic-nvenc"):
        videos = {path for path in paths if path.suffix == ".hevc"}
        if data.get("schema_version") != 1 or not 1 <= len(videos) <= 8 or paths != videos | {path.with_suffix(".json") for path in videos}:
            raise ValueError("expected one to eight paired synthetic clips")
        if len({path.stem for path in videos}) != len(videos):
            raise ValueError("duplicate corpus clip name")
    elif len(checked) != 6:
        raise ValueError("expected the six audited corpus files")
    return {"source_commit": data["source_commit"], "files": checked}


def revision():
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True, check=True).stdout != ""
    digest = hashlib.sha256()
    # Hash only implementation and fixture inputs; never scan credentials or local configuration.
    inputs = ("macos/Package.swift", "tools/windows/lab.py", "tools/windows/generate-corpus.py", "tools/windows/inventory.ps1", "tools/windows/build-platform-probe.ps1", "tools/windows/prepare-swift-core.py", "tools/windows/build-swift-core-probe.ps1", "tools/windows/package-swift-core-probe.ps1", "tools/windows/src/core_bridge.swift", "tools/windows/src/core_abi_probe.cpp", "tools/windows/src/platform_probe.cpp", "tools/windows/src/mf_decode_probe.cpp", "tools/windows/reference/swift-core-package.resolved", "tools/windows/tests/test_lab.py")
    candidates = [ROOT / name for name in inputs]
    for directory, suffix in (("macos/Sources", ".swift"), ("macos/Tests", ".swift"), ("tools/windows/reference", ".hevc"), ("tools/windows/reference", ".json")):
        candidates.extend((ROOT / directory).rglob("*" + suffix))
    for path in sorted(candidates, key=lambda item: item.relative_to(ROOT).as_posix()):
        digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return {"commit": sha, "dirty": dirty, "implementation_sha256": digest.hexdigest()}


def inventory(alias, run=subprocess.run, known_hosts=None):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", alias):
        raise ValueError("use a configured SSH alias, without user, options or shell syntax")
    # Read the script from stdin to avoid Windows command-line length limits.
    command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -Command "[ScriptBlock]::Create([Console]::In.ReadToEnd()).Invoke()"'
    args = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", alias, command]
    if known_hosts is not None:
        args[1:1] = ["-o", "UserKnownHostsFile=" + str(known_hosts.resolve())]
    try:
        result = run(args, input=(ROOT / "tools/windows/inventory.ps1").read_text(), capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired:
        return {"status": "blocked", "reason": "remote_inventory_timeout"}
    if result.returncode:
        error = result.stderr.lower()
        if "host key verification failed" in error or "remote host identification has changed" in error:
            reason = "ssh_host_identity_unverified"
        elif "permission denied" in error:
            reason = "ssh_authentication_failed"
        else:
            reason = "ssh_or_remote_command_failed"
        return {"status": "blocked", "reason": reason, "exit_code": result.returncode}
    try:
        data = json.loads(result.stdout.lstrip("\ufeff").strip())
    except (ValueError, TypeError):
        return {"status": "failed", "reason": "invalid_inventory_json"}
    if not isinstance(data, dict) or data.get("schema_version") != 1 or data.get("platform") != "windows":
        return {"status": "failed", "reason": "invalid_inventory_schema"}
    # Partial inventory remains partial, even if optional commands were unavailable.
    complete = bool(data.get("os") and data.get("cpu") and data.get("gpu") and data.get("ram_bytes"))
    return {"status": "collected" if complete else "partial", "inventory": data}


def frame_hashes(path):
    frames = []
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = [field.strip() for field in line.split(",")]
        if len(fields) != 6 or not re.fullmatch(r"[0-9a-f]{64}", fields[5]):
            raise ValueError("invalid FFmpeg framehash row")
        frames.append({"bytes": int(fields[4]), "sha256": fields[5]})
    if not frames:
        raise ValueError("empty decoded output")
    return frames


def verify_swift_tests(log, exit_code, minimum_tests=80):
    if minimum_tests < 1:
        raise ValueError("minimum test count must be positive")
    summaries = re.findall(r"Test run with (\d+) tests? in \d+ suites? passed", log.read_text(encoding="utf-8", errors="replace"))
    count = max((int(value) for value in summaries), default=0)
    passed = exit_code == 0 and count >= minimum_tests
    return {"status": "passed" if passed else "failed", "exit_code": exit_code, "tests": count, "minimum_tests": minimum_tests, "reason": "test_count_verified" if passed else "test_failure_or_missing_discovery"}


def select_adapter(platform, index):
    matches = [adapter for adapter in platform.get("adapters", []) if adapter.get("index") == index]
    if len(matches) != 1:
        raise ValueError("requested DXGI adapter does not exist")
    adapter = matches[0]
    if adapter.get("software") or adapter.get("device_hresult") != 0 or not adapter.get("hevc_main_profile"):
        raise ValueError("requested adapter cannot provide hardware HEVC Main decoding")
    return adapter


def decode_reference(output, ffmpeg, ffprobe, backend="software", adapter_index=0, mf_probe=None, corpus_manifest=MANIFEST):
    if backend != "software" and sys.platform != "win32":
        raise ValueError("hardware backends require native Windows")
    if not 0 <= adapter_index < 16:
        raise ValueError("adapter index must be between 0 and 15")
    adapter = None
    if backend != "software":
        discovered = subprocess.run([str(ROOT / "tools/windows/results/platform-build/platform_probe.exe")], capture_output=True, text=True, timeout=10, check=True)
        adapter = select_adapter(json.loads(discovered.stdout), adapter_index)
    corpus = verify_corpus(manifest=corpus_manifest)
    version = subprocess.run([ffmpeg, "-version"], capture_output=True, text=True, timeout=10, check=True).stdout.splitlines()[0]
    probe_version = subprocess.run([ffprobe, "-version"], capture_output=True, text=True, timeout=10, check=True).stdout.splitlines()[0]
    clips = []
    for item in corpus["files"]:
        if not item["path"].endswith(".hevc"):
            continue
        path = ROOT / item["path"]
        metadata = json.loads(path.with_suffix(".json").read_text())
        probe = subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,profile,width,height,pix_fmt", "-of", "json", str(path)], capture_output=True, text=True, timeout=20, check=True)
        streams = json.loads(probe.stdout)["streams"]
        if len(streams) != 1:
            raise ValueError("expected one video stream")
        stream = streams[0]
        if stream.get("codec_name") != "hevc" or stream.get("profile") != "Main" or stream.get("pix_fmt") != "yuv420p" or stream.get("width") != metadata["width"] or stream.get("height") != metadata["height"]:
            raise ValueError("unexpected reference format: " + path.name)
        target = output / (path.stem + ".framehash")
        start = time.monotonic()
        probe_metrics = None
        hardware = ["-init_hw_device", f"d3d11va=gpu:{adapter_index}", "-hwaccel", "d3d11va", "-hwaccel_device", "gpu", "-hwaccel_output_format", "d3d11"] if backend == "d3d11va" else ["-hwaccel", "none"]
        download = ["-vf", "hwdownload,format=nv12,format=yuv420p"] if backend == "d3d11va" else []
        command = [ffmpeg, "-hide_banner", "-loglevel", "verbose" if backend == "d3d11va" else "error", "-nostdin", "-xerror"] + hardware + ["-c:v", "hevc", "-i", str(path), "-map", "0:v:0", "-an", "-sn"] + download + ["-pix_fmt", "yuv420p", "-fps_mode", "passthrough", "-f", "framehash", "-hash", "sha256", "-n", str(target)]
        if backend == "media-foundation":
            if adapter_index != 0:
                raise ValueError("Media Foundation spike currently uses adapter 0")
            container = output / (path.stem + ".mp4")
            remux = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-r", str(metadata["fps"]), "-i", str(path), "-map", "0:v:0", "-c:v", "copy", "-tag:v", "hvc1", "-n", str(container)], capture_output=True, text=True, timeout=30)
            if remux.returncode or remux.stderr.strip():
                raise ValueError("HEVC remux failed")
            executable = mf_probe or ROOT / "tools/windows/results/platform-build/mf_decode_probe.exe"
            command = [str(executable), str(container), str(target)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if backend == "media-foundation" and result.returncode == 0:
            probe_metrics = json.loads(result.stdout)
            (output / (path.stem + ".probe.json")).write_text(json.dumps(probe_metrics, indent=2) + "\n")
            if probe_metrics.get("gpu_frames") != len(metadata["frames"]) or probe_metrics.get("width") != metadata["width"] or probe_metrics.get("height") != metadata["height"]:
                raise ValueError("Media Foundation output count or dimensions mismatch")
        diagnostic = result.stderr.replace(str(ROOT), "<CHECKOUT>").replace(ROOT.as_posix(), "<CHECKOUT>")
        (output / (path.stem + ".decode.log")).write_text(diagnostic)
        if result.returncode or (backend == "software" and result.stderr.strip()):
            raise ValueError("decode failed or reported errors: " + path.name)
        frames = frame_hashes(target)
        if len(frames) != len(metadata["frames"]):
            raise ValueError("decoded frame count mismatch: " + path.name)
        if any(frame["bytes"] != metadata["width"] * metadata["height"] * 3 // 2 for frame in frames):
            raise ValueError("decoded frame size mismatch: " + path.name)
        clips.append({"clip": path.stem, "input_sha256": item["sha256"], "format": stream, "probe_metrics": probe_metrics, "frames": len(frames), "framehash_file": target.name, "framehash_sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "wall_seconds": round(time.monotonic() - start, 6)})
    return {"status": "passed", "backend": ("media-foundation-d3d11" if backend == "media-foundation" else "ffmpeg-hevc-" + backend), "adapter_index": adapter_index if backend != "software" else None, "adapter": adapter, "ffmpeg": version, "ffprobe": probe_version, "clips": clips, "limits": ["Full clips decoded without simulated loss", "Decode correctness only; no presentation, FPS or latency qualification", "Hardware probes use GPU-to-CPU download for pixel hashing; this is not the final rendering path", "Wall time includes process startup, conversion and hashing"]}


def load_decode_run(directory):
    data = json.loads((directory / "result.json").read_text())
    if data.get("schema_version") != 1 or data.get("status") != "passed" or data.get("action") != "decode-reference":
        raise ValueError("expected a successful schema-1 decode-reference run")
    clips = {}
    for clip in data.get("clips", []):
        name = clip["clip"]
        if name in clips:
            raise ValueError("duplicate clip in decode result")
        path = (directory / clip["framehash_file"]).resolve()
        if not path.is_relative_to(directory.resolve()) or path.suffix != ".framehash":
            raise ValueError("invalid framehash path")
        if hashlib.sha256(path.read_bytes()).hexdigest() != clip["framehash_sha256"]:
            raise ValueError("framehash artifact checksum mismatch")
        frames = frame_hashes(path)
        if len(frames) != clip["frames"]:
            raise ValueError("framehash artifact count mismatch")
        clips[name] = (clip, frames)
    if not clips:
        raise ValueError("decode result has no clips")
    return data, clips


def compare_reference(reference, candidate):
    if reference.resolve() == candidate.resolve():
        raise ValueError("reference and candidate must be separate runs")
    reference_data, expected = load_decode_run(reference)
    candidate_data, actual = load_decode_run(candidate)
    if expected.keys() != actual.keys():
        raise ValueError("reference and candidate clip sets differ")
    comparisons = []
    for name, (metadata, frames) in expected.items():
        other, decoded = actual[name]
        if metadata["input_sha256"] != other["input_sha256"] or metadata["format"] != other["format"]:
            raise ValueError("input or pixel format differs between runs")
        mismatches = [index for index in range(max(len(frames), len(decoded))) if index >= len(frames) or index >= len(decoded) or frames[index] != decoded[index]]
        comparisons.append({"clip": name, "reference_frames": len(frames), "candidate_frames": len(decoded), "mismatched_frames": len(mismatches), "first_mismatch_indices": mismatches[:20]})
    mismatched = sum(clip["mismatched_frames"] for clip in comparisons)
    return {"status": "passed" if mismatched == 0 else "failed", "reason": "identical_decoded_pixels" if mismatched == 0 else "decoded_pixels_differ", "reference_run_id": reference_data["run_id"], "candidate_run_id": candidate_data["run_id"], "clips": comparisons, "limits": ["Pixel equality only; does not qualify hardware acceleration, presentation or latency", "A mismatch needs pixel/color-conversion investigation before attributing a decoder fault"]}


def load_presentation_run(directory):
    summary_path, csv_path = directory / "result.json", directory / "result.csv"
    data = json.loads(summary_path.read_text())
    if data.get("schema_version") != 1 or data.get("status") != "passed" or type(data.get("maximum_frame_latency")) is not int or data.get("maximum_frame_latency") not in (1, 2):
        raise ValueError("expected a successful presentation run with queue depth 1 or 2")
    count = data.get("frames_submitted")
    if type(count) is not int or not 120 <= count <= 1200:
        raise ValueError("invalid presentation frame count")
    if (data.get("buffer_width"), data.get("buffer_height")) not in ((1920, 1080), (2560, 1440), (3840, 2160)):
        raise ValueError("unsupported presentation dimensions")
    fields = ["frame", "wait_ms", "cpu_submit_ms", "present_call_ms", "submit_interval_ms"]
    with csv_path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != fields:
            raise ValueError("unexpected presentation CSV columns")
        rows = list(reader)
    if len(rows) != count:
        raise ValueError("presentation CSV frame count mismatch")
    values = {field: [] for field in fields[1:]}
    for index, row in enumerate(rows):
        if None in row or None in row.values() or row["frame"] != str(index):
            raise ValueError("presentation frame sequence is incomplete or reordered")
        for field in values:
            value = float(row[field])
            if not math.isfinite(value) or value < 0:
                raise ValueError("invalid presentation measurement")
            values[field].append(value)
    intervals = values["submit_interval_ms"][1:]
    if values["submit_interval_ms"][0] != 0 or any(value <= 0 for value in intervals):
        raise ValueError("invalid presentation intervals")
    phases = [sum(values[field][index] for field in ("wait_ms", "cpu_submit_ms", "present_call_ms")) for index in range(count)]
    if any(phase > interval + .001 for phase, interval in zip(phases[1:], intervals)):
        raise ValueError("presentation phase durations exceed their frame interval")
    wall = data.get("wall_seconds", 0)
    if type(wall) not in (int, float) or not math.isfinite(wall) or not 0 < wall <= 30:
        raise ValueError("invalid presentation duration")
    expected = {"present_calls_per_second": count / wall}
    for percentile in (50, 95, 99):
        expected[f"submit_interval_p{percentile}_ms"] = sorted(intervals)[math.ceil(len(intervals) * percentile / 100) - 1]
    expected["wait_p95_ms"] = sorted(values["wait_ms"])[math.ceil(count * .95) - 1]
    expected["present_call_p95_ms"] = sorted(values["present_call_ms"])[math.ceil(count * .95) - 1]
    for field, value in expected.items():
        reported = data.get(field)
        # Native JSON/CSV use six significant digits, so allow only their rounding error.
        if type(reported) not in (int, float) or not math.isfinite(reported) or not math.isclose(reported, value, rel_tol=2e-5, abs_tol=1e-6):
            raise ValueError("presentation summary differs from raw measurements: " + field)
    if sum(intervals) + phases[0] > wall * 1000 + .1:
        raise ValueError("presentation intervals exceed wall duration")
    return {"maximum_frame_latency": data["maximum_frame_latency"], "buffer_width": data["buffer_width"], "buffer_height": data["buffer_height"], "frames_submitted": count, "wall_seconds": wall, **expected, "interval_min_ms": min(intervals), "interval_max_ms": max(intervals), "intervals_over_25_ms": sum(value > 25 for value in intervals), "summary_sha256": hashlib.sha256(summary_path.read_bytes()).hexdigest(), "csv_sha256": hashlib.sha256(csv_path.read_bytes()).hexdigest()}


def compare_presentation(reference, candidate):
    if reference.resolve() == candidate.resolve():
        raise ValueError("presentation comparison requires separate runs")
    runs = sorted([load_presentation_run(reference), load_presentation_run(candidate)], key=lambda run: run["maximum_frame_latency"])
    if [run["maximum_frame_latency"] for run in runs] != [1, 2]:
        raise ValueError("presentation comparison requires queue depths 1 and 2")
    if any(runs[0][field] != runs[1][field] for field in ("buffer_width", "buffer_height", "frames_submitted")):
        raise ValueError("presentation workload differs between runs")
    return {"status": "passed", "qualification": "synthetic_submission_smoke_only", "runs": runs, "queue_2_minus_1_p99_ms": runs[1]["submit_interval_p99_ms"] - runs[0]["submit_interval_p99_ms"], "winner": None, "limits": ["One sequential run per queue depth; no statistical performance winner", "Submission timing is not displayed FPS or end-to-end latency", "Synthetic content in a 1280x720 window; no decoder or network integration", "CSV validation checks consistency, not independent proof of display output"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["verify-corpus", "inventory", "decode-reference", "compare-reference", "verify-swift-tests", "compare-presentation"])
    parser.add_argument("--ssh-alias", default="rtx4090")
    parser.add_argument("--known-hosts", type=Path, help="Dedicated file containing an independently verified SSH host key")
    parser.add_argument("--output", type=Path, required=True, help="New run directory; existing directories are never overwritten")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--corpus-manifest", type=Path, default=MANIFEST)
    parser.add_argument("--backend", choices=["software", "d3d11va", "media-foundation"], default="software")
    parser.add_argument("--mf-probe", type=Path)
    parser.add_argument("--adapter-index", type=int, default=0)
    parser.add_argument("--reference-run", type=Path)
    parser.add_argument("--candidate-run", type=Path)
    parser.add_argument("--test-log", type=Path)
    parser.add_argument("--test-exit-code", type=int)
    parser.add_argument("--minimum-tests", type=int, default=80)
    args = parser.parse_args()
    if args.action in ("compare-reference", "compare-presentation") and (args.reference_run is None or args.candidate_run is None):
        parser.error(args.action + " requires --reference-run and --candidate-run")
    if args.action == "verify-swift-tests" and (args.test_log is None or args.test_exit_code is None):
        parser.error("verify-swift-tests requires --test-log and --test-exit-code")
    args.output.mkdir(parents=True, exist_ok=False)
    record = {"schema_version": 1, "run_id": str(uuid.uuid4()), "started_at": datetime.now(timezone.utc).isoformat(), "action": args.action}
    try:
        record["source"] = revision()
        if args.action == "verify-swift-tests":
            record.update(verify_swift_tests(args.test_log, args.test_exit_code, args.minimum_tests))
        elif args.action == "compare-presentation":
            record.update(compare_presentation(args.reference_run, args.candidate_run))
        elif args.action == "compare-reference":
            record.update(compare_reference(args.reference_run, args.candidate_run))
        elif args.action == "verify-corpus":
            record.update(status="passed", corpus=verify_corpus(manifest=args.corpus_manifest))
        elif args.action == "inventory":
            record.update(inventory(args.ssh_alias, known_hosts=args.known_hosts))
        else:
            record.update(decode_reference(args.output, args.ffmpeg, args.ffprobe, args.backend, args.adapter_index, args.mf_probe, args.corpus_manifest))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        record.update(status="failed", reason=type(error).__name__, detail=str(error).replace(str(ROOT), "<CHECKOUT>"))
    (args.output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({key: record[key] for key in ("action", "status", "run_id")}))
    return 0 if record["status"] in ("passed", "collected") else 2


if __name__ == "__main__":
    sys.exit(main())
