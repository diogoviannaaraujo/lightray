#!/usr/bin/env python3
"""Run iPad simulator tests against the Mac's permission-free synthetic host.

Requires a built macos/.build/release/lightray-host and an existing host pairing.
The pairing travels through a private temporary file, never argv or test logs.
"""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="Booted iPadOS 27 simulator UDID")
    parser.add_argument("--port", type=int, default=17373)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = root / "ios/.build"
    output.mkdir(parents=True, exist_ok=True)
    binary = root / "macos/.build/release/lightray-host"
    pairing_file = Path.home() / "Library/Application Support/Lightray/host-pairing"
    if not binary.is_file() or not pairing_file.is_file():
        parser.error("Build the Mac host and run lightray-host pair first; see ios/README.md.")
    # Fail before launching a second host on a port owned by another process.
    with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as probe:
        probe.bind(("::", options.port))

    build = ["xcodebuild", "-project", str(root / "ios/Lightray.xcodeproj"),
             "-scheme", "Lightray", "-destination", f"platform=iOS Simulator,id={options.simulator}",
             "-derivedDataPath", str(output / "simulator"), "CODE_SIGN_IDENTITY=-",
             "COMPILER_INDEX_STORE_ENABLE=NO", "-parallel-testing-enabled", "NO"]
    print("Building iPad test bundle…", flush=True)
    with (output / "smoke-build.log").open("w") as log:
        run(*build, "build-for-testing", stdout=log, stderr=subprocess.STDOUT)
    app = output / "simulator/Build/Products/Debug-iphonesimulator/Lightray.app"
    run("xcrun", "simctl", "install", options.simulator, str(app))
    container = Path(run("xcrun", "simctl", "get_app_container", options.simulator,
                         "io.lightray.ipad", "data", capture_output=True).stdout.strip())
    configuration = container / "Documents/lightray-smoke.json"
    configuration.parent.mkdir(parents=True, exist_ok=True)
    host = None
    test = None
    try:
        token = pairing_file.read_text().strip()
        with os.fdopen(os.open(configuration, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
            json.dump({"address": f"127.0.0.1:{options.port}", "token": token}, file)
        with (output / "smoke-host.log").open("w") as host_log, (output / "smoke-tests.log").open("w") as test_log:
            host = subprocess.Popen([str(binary), "--port", str(options.port), "--test-pattern",
                                     "1280x720", "--log-input", "--warm", "0"],
                                    stdout=host_log, stderr=subprocess.STDOUT)
            time.sleep(1)
            if host.poll() is not None:
                raise RuntimeError("Synthetic host failed; see ios/.build/smoke-host.log")
            print("Testing pairing, cancellation, timeout, video, display switching, input, and reconnect…", flush=True)
            test = subprocess.Popen(build + ["test-without-building"], stdout=test_log, stderr=subprocess.STDOUT)
            screenshot_taken = False
            deadline = time.monotonic() + 240
            while test.poll() is None:
                if time.monotonic() > deadline:
                    raise TimeoutError("Xcode tests did not finish within 240 seconds")
                if not screenshot_taken and "LIGHTRAY_SMOKE_LIVE" in (output / "smoke-tests.log").read_text():
                    run("xcrun", "simctl", "io", options.simulator, "screenshot", str(output / "smoke-stream.png"))
                    screenshot_taken = True
                time.sleep(0.25)
            if test.returncode:
                raise RuntimeError("iPad tests failed; see ios/.build/smoke-tests.log")
        host_text = (output / "smoke-host.log").read_text()
        # Assert input reached the host, in addition to the app-side assertions.
        for expected in ["key(usage: 41, down: true", "key(usage: 41, down: false",
                         "pointer(x: 32768, y: 32768", "button(LightrayCore.InputMessage.PointerButton.left, down: false)"]:
            if expected not in host_text:
                raise AssertionError(f"Missing input evidence in host log: {expected}")
        print("PASS: iPad tests and host-side input delivery. Logs in ios/.build/.", flush=True)
    finally:
        configuration.unlink(missing_ok=True)
        for process in (test, host):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
