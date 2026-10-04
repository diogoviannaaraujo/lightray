#!/usr/bin/env python3
"""Create an isolated copy of the Mac reference for the native NVENC interoperability probe."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]


def prepare(output):
    output = output.resolve()
    results = (ROOT / 'tools/windows/results').resolve()
    if output == results or not output.is_relative_to(results):
        raise ValueError('Output must be inside tools/windows/results')
    output.mkdir(parents=True, exist_ok=False)
    files = []
    source_files = [(path, 'Sources/LightrayCore/' + path.relative_to(ROOT / 'macos/Sources/LightrayCore').as_posix()) for path in sorted((ROOT / 'macos/Sources/LightrayCore').rglob('*.swift'))]
    source_files += [(ROOT / 'macos/Sources/LightrayMac/VideoDecoder.swift', 'Sources/LightrayMac/VideoDecoder.swift'), (ROOT / 'tools/windows/src/nvenc_mac_interop.swift', 'Sources/Interop/main.swift')]
    for source, destination in source_files:
        target = output / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        files.append({'source': source.relative_to(ROOT).as_posix(), 'copy': destination, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    (output / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NVENCInterop", platforms: [.macOS(.v14)], targets: [
    .target(name: "LightrayCore"),
    .target(name: "LightrayMac", dependencies: ["LightrayCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "Interop", dependencies: ["LightrayCore", "LightrayMac"], swiftSettings: [.swiftLanguageMode(.v5)])
])
''')
    (output / 'source-manifest.json').write_text(json.dumps({'files': files}, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    prepare(parser.parse_args().output)
