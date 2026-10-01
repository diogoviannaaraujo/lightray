#!/usr/bin/env python3
"""Generate bounded synthetic HEVC Main clips with macOS VideoToolbox, without screen capture."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ((2560, 1440, "20M"), (3840, 2160, "40M"))


def generate(output, ffmpeg="ffmpeg", ffprobe="ffprobe"):
    if sys.platform != "darwin":
        raise ValueError("VideoToolbox generation requires macOS")
    output = output.resolve()
    if not output.is_relative_to(ROOT):
        raise ValueError("output must be inside the checkout")
    output.mkdir(parents=True, exist_ok=False)
    version = subprocess.run([ffmpeg, "-version"], capture_output=True, text=True, timeout=10, check=True).stdout.splitlines()[0]
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    manifest = {"schema_version": 1, "kind": "synthetic-videotoolbox", "created_at": datetime.now(timezone.utc).isoformat(), "source_commit": commit, "ffmpeg": version, "source": "lavfi testsrc2; no user screen captured", "limits": ["Encoder output may vary between OS and hardware; use recorded byte hashes for comparisons", "Synthetic P-frame corpus; not an end-to-end Lightray stream"], "commands": [], "files": []}
    for width, height, bitrate in PROFILES:
        path = output / f"videotoolbox-synthetic-{width}x{height}.hevc"
        command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", f"testsrc2=size={width}x{height}:rate=60", "-frames:v", "120", "-c:v", "hevc_videotoolbox", "-profile:v", "main", "-pix_fmt", "yuv420p", "-allow_sw", "0", "-realtime", "1", "-bf", "0", "-g", "60", "-b:v", bitrate, "-f", "hevc", "-n", str(path)]
        encoded = subprocess.run(command, capture_output=True, text=True, timeout=60)
        (output / (path.stem + ".encode.log")).write_text(encoded.stderr)
        if encoded.returncode or encoded.stderr.strip():
            raise ValueError("VideoToolbox encoding failed; inspect the encode log")
        probe = subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,profile,width,height,pix_fmt:frame=pict_type,key_frame", "-of", "json", str(path)], capture_output=True, text=True, timeout=30, check=True)
        data = json.loads(probe.stdout)
        expected = {"codec_name": "hevc", "profile": "Main", "width": width, "height": height, "pix_fmt": "yuv420p"}
        frames = data.get("frames", [])
        if data.get("streams") != [expected] or len(frames) != 120 or any(frame.get("pict_type") not in ("I", "P") for frame in frames):
            raise ValueError("encoded stream violates Main 8-bit 4:2:0 I/P profile")
        metadata = {"width": width, "height": height, "fps": 60, "frames": frames, "source": "synthetic testsrc2", "profile": "Main", "pixel_format": "yuv420p", "requested_bitrate": bitrate}
        path.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
        manifest["commands"].append([part.replace(str(ROOT), "<CHECKOUT>") for part in command])
        for artifact in (path, path.with_suffix(".json")):
            payload = artifact.read_bytes()
            manifest["files"].append({"path": artifact.relative_to(ROOT).as_posix(), "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return {"status": "passed", "clips": len(PROFILES), "frames": 240, "output": output.relative_to(ROOT).as_posix()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    args = parser.parse_args()
    try:
        print(json.dumps(generate(args.output, args.ffmpeg, args.ffprobe)))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "failed", "reason": type(error).__name__, "detail": str(error).replace(str(ROOT), "<CHECKOUT>")}))
        sys.exit(2)
