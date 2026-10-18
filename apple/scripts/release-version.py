#!/usr/bin/env python3
"""Validate Apple and Windows versions before signing or publishing anything."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[2]


def version():
    plists = ['mac-client/App/Info.plist', 'mac-host/App/Info.plist', 'mac-host/App/Service-Info.plist']
    infos = [plistlib.loads((ROOT / 'apple' / path).read_bytes()) for path in plists]
    value = infos[0]['CFBundleShortVersionString']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', value):
        raise ValueError('Release version must use MAJOR.MINOR.PATCH')
    for path, info in zip(plists, infos):
        if (info['CFBundleShortVersionString'], info['CFBundleVersion']) != (
                value, infos[0]['CFBundleVersion']):
            raise ValueError(f'Version/build mismatch in {path}')
    project = json.loads(subprocess.check_output([
        'plutil', '-convert', 'json', '-o', '-',
        ROOT / 'apple/ios-client/Lightray.xcodeproj/project.pbxproj']))
    for item in project['objects'].values():
        settings = item.get('buildSettings', {})
        if 'MARKETING_VERSION' in settings and settings['MARKETING_VERSION'] != value:
            raise ValueError('The iOS marketing version must match the Mac apps')
    cargo = tomllib.loads((ROOT / 'windows/Cargo.toml').read_text())
    if cargo['workspace']['package']['version'] != value:
        raise ValueError('The Windows workspace version must match the Apple apps')
    return value


if __name__ == '__main__':
    value = version()
    if len(sys.argv) > 1 and sys.argv[1] != 'v' + value:
        raise ValueError('Release tag must match v' + value)
    print(value)
