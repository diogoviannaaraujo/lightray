#!/usr/bin/env python3
"""Build independent Lightray and Lightray Host apps and DMGs on macOS with Xcode 27."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

APPLE = Path(__file__).resolve().parents[1]
ROOT = APPLE.parent


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def read_plist(path):
    with path.open('rb') as source:
        return plistlib.load(source)


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('wb') as destination:
        plistlib.dump(value, destination)


def copy_executable(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    destination.chmod(0o755)


def package_app(role, options, output):
    package = APPLE / f'mac-{role}'
    host = role == 'host'
    name = 'Lightray Host' if host else 'Lightray'
    asset_name = 'LightrayHost' if host else 'Lightray'
    build = ['swift', 'build', '-c', 'release', '--package-path', package, '--arch', 'arm64']
    if not options.skip_build:
        run(*build)
    binary_dir = Path(run(*build, '--show-bin-path', capture_output=True, text=True).stdout.strip())
    signing = ['--force', '--sign', options.sign]
    if options.sign != '-':
        signing += ['--options', 'runtime', '--timestamp']
    with tempfile.TemporaryDirectory(prefix=f'lightray-{role}-', dir=output) as temporary:
        stage = Path(temporary)
        app = stage / f'{name}.app'
        resources = app / 'Contents/Resources'
        resources.mkdir(parents=True)
        info = read_plist(package / 'App/Info.plist')
        copy_executable(binary_dir / ('lightray-host-app' if host else 'lightray-client'),
                        app / 'Contents/MacOS' / info['CFBundleExecutable'])
        (app / 'Contents/PkgInfo').write_bytes(b'APPL????')
        icon = ROOT / 'assets/lightray.icon'
        icon_info = stage / 'icon-info.plist'
        run('xcrun', 'actool', icon, '--compile', resources,
            '--output-format', 'human-readable-text', '--notices', '--warnings',
            '--platform', 'macosx', '--minimum-deployment-target', info['LSMinimumSystemVersion'],
            '--target-device', 'mac', '--app-icon', icon.stem,
            '--output-partial-info-plist', icon_info)
        info.update(read_plist(icon_info))
        write_plist(app / 'Contents/Info.plist', info)
        if host:
            helper = app / 'Contents/Library/LoginItems/LightrayHostService.app'
            copy_executable(binary_dir / 'lightray-host', helper / 'Contents/MacOS/lightray-host')
            write_plist(helper / 'Contents/Info.plist', read_plist(package / 'App/Service-Info.plist'))
            write_plist(app / 'Contents/Library/LaunchAgents/io.lightray.mac.host.service.plist',
                        read_plist(package / 'App/io.lightray.mac.host.service.plist'))
            run('codesign', *signing, helper)
        run('codesign', *signing, app)
        run('codesign', '--verify', '--deep', '--strict', app)
        run('plutil', '-lint', app / 'Contents/Info.plist')
        destination = output / f'{name}.app'
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(app, destination)
        print(f'App: {destination}', flush=True)
        if not options.no_dmg:
            disk = stage / 'disk'
            disk.mkdir()
            run('ditto', destination, disk / destination.name)
            (disk / 'Applications').symlink_to('/Applications')
            dmg = output / f"{asset_name}-{info['CFBundleShortVersionString']}-arm64.dmg"
            run('hdiutil', 'create', '-volname', name, '-srcfolder', disk, '-format', 'UDZO', '-ov', dmg)
            if options.sign != '-':
                run('codesign', *signing, dmg)
            print(f'Disk image: {dmg}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', choices=['client', 'host', 'all'], default='all')
    parser.add_argument('--output', type=Path, help='Output directory; default: apple/.build/apps')
    parser.add_argument('--sign', default=os.environ.get('CODE_SIGN_IDENTITY', '-'))
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--no-dmg', action='store_true')
    options = parser.parse_args()
    client = read_plist(APPLE / 'mac-client/App/Info.plist')
    for filename in ('Info.plist', 'Service-Info.plist'):
        host = read_plist(APPLE / 'mac-host/App' / filename)
        for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
            if client[key] != host[key]:
                parser.error(f'Mac client, host, and service must have matching {key}')
    output = (options.output or APPLE / '.build/apps').resolve()
    output.mkdir(parents=True, exist_ok=True)
    for role in (['client', 'host'] if options.app == 'all' else [options.app]):
        package_app(role, options, output)
    if options.sign == '-':
        print('Local ad-hoc signatures. Public distribution requires Developer ID signing and notarization.')


if __name__ == '__main__':
    main()
