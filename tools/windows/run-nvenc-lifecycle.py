#!/usr/bin/env python3
"""Validate bounded NVENC lifecycle and per-process resource trends, without desktop capture."""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SIZES = ((1920, 1080), (2560, 1440), (3840, 2160))
# Predeclared laboratory guardrails, not a leak proof or a production acceptance threshold.
GROWTH_LIMITS = {'private_bytes': 32 << 20, 'gpu_local_bytes': 16 << 20, 'gpu_nonlocal_bytes': 16 << 20, 'handles': 8}


def verify_frames(rows, decoded):
    if len(rows) != 600 or len(decoded) != 600:
        raise ValueError('Expected 600 encoded and decoded frames')
    for index, (row, frame) in enumerate(zip(rows, decoded)):
        cycle, offset = divmod(index, 6)
        width, height = SIZES[(cycle + (offset >= 4)) % 3]
        generation = 1 if offset < 3 else 2 if offset == 3 else 4 if cycle % 2 == 0 else 3
        idr = offset in (0, 2, 3, 4)
        expected = {'frame': index, 'cycle': cycle, 'width': width, 'height': height, 'generation': generation, 'timestamp': offset, 'idr': int(idr)}
        if any(int(row[key]) != value for key, value in expected.items()):
            raise ValueError('Lifecycle frame metadata mismatch')
        elapsed = float(row['encode_and_lock_ms'])
        if not math.isfinite(elapsed) or elapsed < 0:
            raise ValueError('Invalid encoder timing')
        if frame.get('width') != width or frame.get('height') != height or frame.get('pict_type') != ('I' if idr else 'P') or frame.get('pix_fmt') != 'yuv420p':
            raise ValueError('Independent decoder dimensions/type mismatch')
    return {'frames': 600, 'idr_frames': 400, 'resolution_changes': 100, 'independent_decode_verified': True}


def verify_resources(rows):
    if len(rows) != 131 or [int(row['cycle']) for row in rows] != list(range(-31, 100)):
        raise ValueError('Incomplete resource samples')
    result = {}
    for key in (*GROWTH_LIMITS, 'working_set_bytes'):
        values = [int(row[key]) for row in rows]
        if any(value < 0 for value in values):
            raise ValueError('Negative resource sample')
        cold = values[0]
        values = values[-101:]
        early = statistics.median(values[1:21])
        late = statistics.median(values[-20:])
        difference = late - early
        result[key] = {'cold_baseline': cold, 'warmup_growth': values[0] - cold, 'baseline': values[0], 'first_20_median': early, 'last_20_median': late, 'growth': difference, 'maximum': max(values), 'final': values[-1], 'growth_limit': GROWTH_LIMITS.get(key)}
        if key in GROWTH_LIMITS and difference > GROWTH_LIMITS[key]:
            raise ValueError(f'Resource trend exceeds declared guardrail: {key}')
    return result


def run(output, executable, ffprobe):
    if sys.platform != 'win32':
        raise ValueError('Lifecycle execution requires native Windows')
    output = output.resolve()
    if not output.is_relative_to(ROOT / 'tools/windows/results') or output == ROOT / 'tools/windows/results':
        raise ValueError('Output must be a new directory inside tools/windows/results')
    output.mkdir(parents=True, exist_ok=False)
    provenance = {'status': 'running', 'kind': 'native-nvenc-lifecycle', 'desktop_captured': False, 'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(), 'inputs': {}}
    for name in ('src/nvenc_encoder.hpp', 'src/nvenc_encoder.cpp', 'src/nvenc_lifecycle_probe.cpp', 'src/hevc_annexb.hpp', 'vendor/nv-codec-headers/nvEncodeAPI.h', 'run-nvenc-lifecycle.py', 'build-nvenc-probe.ps1'):
        provenance['inputs'][name] = hashlib.sha256((ROOT / 'tools/windows' / name).read_bytes()).hexdigest()
    try:
        target = output / 'native'
        process = subprocess.run([str(executable), str(target)], capture_output=True, text=True, timeout=180)
        (output / 'native.log').write_text(process.stdout + process.stderr)
        provenance['exit_code'] = process.returncode
        if process.returncode or process.stderr.strip():
            raise ValueError('Lifecycle failed or reported cleanup errors')
        summary = json.loads((target / 'result.json').read_text())
        if any(summary.get(k) != v for k, v in {'status': 'passed', 'cycles': 100, 'reconfigurations': 100, 'frames': 600, 'warmup_cycles': 30, 'warmup_sessions': 60, 'resource_samples': 131, 'desktop_captured': False}.items()):
            raise ValueError('Lifecycle summary mismatch')
        oracle = subprocess.run([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=width,height,pict_type,pix_fmt', '-of', 'json', str(target / 'lifecycle.hevc')], capture_output=True, text=True, timeout=90, check=True)
        if oracle.stderr.strip():
            raise ValueError('Independent decoder reported an error')
        inspection = json.loads(oracle.stdout)
        (output / 'ffprobe.json').write_text(json.dumps(inspection, indent=2) + '\n')
        with (target / 'frames.csv').open(newline='') as f:
            provenance['frames'] = verify_frames(list(csv.DictReader(f)), inspection['frames'])
        with (target / 'resources.csv').open(newline='') as f:
            provenance['resources'] = verify_resources(list(csv.DictReader(f)))
        provenance['native_summary'] = summary
        provenance['status'] = 'passed'
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        provenance['status'] = 'failed'
        provenance['reason'] = str(error)
        raise
    finally:
        (output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    return provenance


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--executable', type=Path, default=ROOT / 'tools/windows/results/nvenc-build/nvenc_lifecycle_probe.exe')
    parser.add_argument('--ffprobe', default='ffprobe')
    args = parser.parse_args()
    try:
        result = run(args.output, args.executable.resolve(), args.ffprobe)
        print(json.dumps({'status': result['status'], 'frames': result['frames'], 'resources': result['resources']}))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
