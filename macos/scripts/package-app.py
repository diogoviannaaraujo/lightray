#!/usr/bin/env python3
"""Build Lightray.app and a drag-to-Applications disk image. Run on macOS with Xcode 27."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Output directory; default: macos/.build/app")
    parser.add_argument("--sign", default=os.environ.get("CODE_SIGN_IDENTITY", "-"),
                        help="Code-signing identity; defaults to local ad-hoc signing")
    parser.add_argument("--skip-build", action="store_true", help="Package existing Release binaries")
    parser.add_argument("--no-dmg", action="store_true")
    options = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    output = (options.output or package / ".build/app").resolve()
    output.mkdir(parents=True, exist_ok=True)
    build = ["swift", "build", "-c", "release", "--package-path", str(package), "--arch", "arm64"]
    if not options.skip_build:
        run(*build)
    binary_dir = Path(run(*build, "--show-bin-path", capture_output=True, text=True).stdout.strip())
    with tempfile.TemporaryDirectory(prefix="lightray-package-", dir=output) as temporary:
        stage = Path(temporary)
        app = stage / "Lightray.app"
        executable_dir = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        executable_dir.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(binary_dir / "lightray-client", executable_dir / "Lightray")
        shutil.copy2(binary_dir / "lightray-host", executable_dir / "lightray-host")
        (app / "Contents/PkgInfo").write_bytes(b"APPL????")
        icon = package.parent / "assets/lightray.icon"
        icon_info = stage / "icon-info.plist"
        with (package / "App/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        run("xcrun", "actool", icon, "--compile", resources,
            "--output-format", "human-readable-text", "--notices", "--warnings",
            "--platform", "macosx", "--minimum-deployment-target", info["LSMinimumSystemVersion"],
            "--target-device", "mac", "--app-icon", icon.stem,
            "--output-partial-info-plist", icon_info)
        with icon_info.open("rb") as source:
            info.update(plistlib.load(source))
        with (app / "Contents/Info.plist").open("wb") as destination_info:
            plistlib.dump(info, destination_info)
        # Sign embedded code first, then seal the complete app. Ad-hoc builds stay local.
        signing = ["--force", "--sign", options.sign]
        if options.sign != "-":
            signing += ["--options", "runtime", "--timestamp"]
        run("codesign", *signing, executable_dir / "lightray-host")
        run("codesign", *signing, app)
        run("codesign", "--verify", "--deep", "--strict", app)
        run("plutil", "-lint", app / "Contents/Info.plist")
        destination = output / "Lightray.app"
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(app, destination)
        print(f"App: {destination}", flush=True)
        if not options.no_dmg:
            disk = stage / "disk"
            disk.mkdir()
            run("ditto", destination, disk / "Lightray.app")
            (disk / "Applications").symlink_to("/Applications")
            with (destination / "Contents/Info.plist").open("rb") as source:
                version = plistlib.load(source)["CFBundleShortVersionString"]
            dmg = output / f"Lightray-{version}-arm64.dmg"
            run("hdiutil", "create", "-volname", "Lightray", "-srcfolder", disk,
                "-format", "UDZO", "-ov", dmg)
            if options.sign != "-":
                run("codesign", *signing, dmg)
            print(f"Disk image: {dmg}", flush=True)
        if options.sign == "-":
            print("Local ad-hoc signature. Public distribution requires Developer ID signing and notarization.")


if __name__ == "__main__":
    main()
