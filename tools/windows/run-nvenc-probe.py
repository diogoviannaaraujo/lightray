#!/usr/bin/env python3
"""Bounded native NVENC experiments with synthetic pixels; never captures the desktop."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def records(data):
    result = []
    offset = 0
    while offset < len(data):
        if len(data) - offset < 4:
            raise ValueError('Truncated length prefix')
        count = int.from_bytes(data[offset:offset + 4], 'big')
        offset += 4
        if count > 32 * 1024 * 1024 or count > len(data) - offset:
            raise ValueError('Invalid record length')
        result.append(data[offset:offset + count])
        offset += count
        if len(result) > 4096:
            raise ValueError('Too many records')
    return result


def verify_records(payload_bytes, config_bytes, rows):
    payloads, configs = records(payload_bytes), records(config_bytes)
    if len(payloads) != 120 or len(configs) != 120 or len(rows) != 120:
        raise ValueError('Expected 120 complete frames')
    reconstructed = bytearray()
    for index, (payload, config, row) in enumerate(zip(payloads, configs, rows)):
        nals = records(payload)
        if not nals or any(len(nal) < 2 or nal[0] & 128 or not nal[1] & 7 for nal in nals):
            raise ValueError('Malformed length-prefixed HEVC payload')
        types = [(nal[0] >> 1) & 63 for nal in nals]
        idr = index in (0, 60)
        vcl = [kind for kind in types if kind <= 31]
        if not vcl or any(kind not in ((19, 20) if idr else tuple(range(10))) for kind in vcl):
            raise ValueError('Unexpected recovery frame or IDR placement')
        expected = b''.join(len(nal).to_bytes(4, 'big') + nal for kind in (32, 33, 34) for nal in nals if (nal[0] >> 1) & 63 == kind) if idr else b''
        if idr and any(types.count(kind) != 1 for kind in (32, 33, 34)):
            raise ValueError('IDR missing unique parameter sets')
        if config != expected or len(config) > 65532:
            raise ValueError('Codec configuration mismatch')
        if any(int(row[key]) != value for key, value in [('frame', index), ('output_timestamp', index), ('idr', int(idr)), ('payload_bytes', len(payload)), ('config_bytes', len(config))]):
            raise ValueError('Frame metadata mismatch')
        elapsed = float(row['encode_and_lock_ms'])
        if not math.isfinite(elapsed) or elapsed < 0 or int(row['annexb_bytes']) <= 0:
            raise ValueError('Invalid frame measurements')
        for nal in nals:
            reconstructed.extend(b'\0\0\0\1' + nal)
    return bytes(reconstructed)


def run(output, executable, ffprobe):
    if sys.platform != 'win32':
        raise ValueError('Native encoder execution requires Windows')
    output = output.resolve()
    results = (ROOT / 'tools/windows/results').resolve()
    if output == results or not output.is_relative_to(results):
        raise ValueError('Output must be a new directory inside tools/windows/results')
    output.mkdir(parents=True, exist_ok=False)
    corpus = output / 'corpus'
    corpus.mkdir()
    manifest = {'schema_version': 1, 'kind': 'synthetic-nvenc', 'source_commit': subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip(), 'created_at': datetime.now(timezone.utc).isoformat(), 'source': 'Native NVENC API; synthetic NV12; no desktop capture', 'files': []}
    provenance = {'schema_version': 1, 'platform': 'native-windows', 'encoder_executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(), 'source_files': [], 'runs': []}
    for name in ('src/nvenc_encoder.hpp', 'src/nvenc_encoder.cpp', 'src/nvenc_encode_probe.cpp', 'src/hevc_annexb.hpp', 'src/hevc_annexb_tests.cpp', 'build-nvenc-probe.ps1', 'run-nvenc-probe.py', 'vendor/nv-codec-headers/nvEncodeAPI.h'):
        provenance['source_files'].append({'path': 'tools/windows/' + name, 'sha256': hashlib.sha256((ROOT / 'tools/windows' / name).read_bytes()).hexdigest()})
    try:
        for width, height in ((1920, 1080), (2560, 1440), (3840, 2160)):
            target = output / f'{width}x{height}'
            completed = subprocess.run([str(executable), str(width), str(height), '0', str(target)], capture_output=True, text=True, timeout=45)
            (output / f'{width}x{height}.log').write_text(completed.stdout + completed.stderr)
            if completed.returncode:
                raise ValueError(f'Native NVENC failed for {width}x{height}; exit {completed.returncode}')
            summary = json.loads((target / 'result.json').read_text())
            if summary.get('status') != 'passed' or summary.get('backend') != 'native-nvenc-d3d11' or summary.get('frames') != 120 or summary.get('width') != width or summary.get('height') != height or summary.get('software_encoder_fallback') is not False or summary.get('desktop_captured') is not False:
                raise ValueError('Native encoder summary mismatch')
            with (target / 'frames.csv').open(newline='') as stream:
                rows = list(csv.DictReader(stream))
            rebuilt = verify_records((target / 'native-nvenc.payloads').read_bytes(), (target / 'native-nvenc.configs').read_bytes(), rows)
            (target / 'reconstructed.hevc').write_bytes(rebuilt)
            # FFprobe is an independent decoder/parser oracle, never the encoder.
            probe = subprocess.run([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=codec_name,profile,width,height,pix_fmt,has_b_frames:frame=pict_type', '-of', 'json', str(target / 'native-nvenc.hevc')], capture_output=True, text=True, timeout=30, check=True)
            if probe.stderr.strip():
                raise ValueError('Independent bitstream inspection reported errors')
            inspection = json.loads(probe.stdout)
            streams = inspection['streams']
            expected_stream = {'codec_name': 'hevc', 'profile': 'Main', 'width': width, 'height': height, 'pix_fmt': 'yuv420p', 'has_b_frames': 0}
            if len(streams) != 1 or any(streams[0].get(k) != v for k, v in expected_stream.items()) or [frame['pict_type'] for frame in inspection['frames']] != ['I' if i in (0, 60) else 'P' for i in range(120)]:
                raise ValueError('Independent bitstream profile or picture sequence mismatch')
            (target / 'ffprobe.json').write_text(json.dumps(inspection, indent=2) + '\n')
            clip = corpus / f'native-nvenc-{width}x{height}.hevc'
            shutil.copy2(target / 'native-nvenc.hevc', clip)
            clip.with_suffix('.json').write_text(json.dumps({'width': width, 'height': height, 'fps': 60, 'frames': [{'index': i, 'idr': i in (0, 60)} for i in range(120)]}, indent=2) + '\n')
            for path in (clip, clip.with_suffix('.json')):
                raw = path.read_bytes()
                manifest['files'].append({'path': path.relative_to(ROOT).as_posix(), 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
            provenance['runs'].append({'resolution': [width, height], 'exit_code': completed.returncode, 'native_summary': summary, 'framing_verified': True, 'independent_profile_verified': True})
        provenance['status'] = 'passed'
        (corpus / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        provenance['status'] = 'failed'
        provenance['reason'] = type(error).__name__
        raise
    finally:
        (output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    return provenance


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--executable', type=Path, default=ROOT / 'tools/windows/results/nvenc-build/nvenc_encode_probe.exe')
    parser.add_argument('--ffprobe', default='ffprobe')
    args = parser.parse_args()
    try:
        result = run(args.output, args.executable.resolve(), args.ffprobe)
        print(json.dumps({'status': result['status'], 'runs': len(result['runs'])}))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
