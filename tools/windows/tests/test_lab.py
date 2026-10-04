import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("lab", Path(__file__).parents[1] / "lab.py")
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class LabTests(unittest.TestCase):
    def test_audited_corpus(self):
        self.assertEqual(len(lab.verify_corpus()["files"]), 6)

    def test_swift_success_requires_discovery_and_success_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            for content, code, status in (("Test run with 0 tests in 0 suites passed", 0, "failed"), ("Build complete!", 0, "failed"), ("Test run with 79 tests in 0 suites passed", 0, "failed"), ("Test run with 80 tests in 0 suites passed", 1, "failed"), ("Test run with 80 tests in 0 suites passed", 0, "passed")):
                log.write_text(content)
                self.assertEqual(lab.verify_swift_tests(log, code)["status"], status)
            log.write_text("Test run with 87 tests in 1 suite passed")
            self.assertEqual(lab.verify_swift_tests(log, 0, 88)["status"], "failed")
            log.write_text("Test run with 88 tests in 1 suite passed")
            self.assertEqual(lab.verify_swift_tests(log, 0, 88)["status"], "passed")

    def test_synthetic_manifest_requires_unique_complete_pairs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = []
            for name in ("clip.hevc", "clip.json"):
                (root / name).write_bytes(b"test")
                files.append({"path": name, "bytes": 4, "sha256": hashlib.sha256(b"test").hexdigest()})
            manifest = root / "manifest.json"
            data = {"schema_version": 1, "kind": "synthetic-videotoolbox", "source_commit": "test", "files": files}
            manifest.write_text(json.dumps(data))
            self.assertEqual(len(lab.verify_corpus(root, manifest)["files"]), 2)
            manifest.write_text(json.dumps(dict(data, kind="synthetic-nvenc")))
            self.assertEqual(len(lab.verify_corpus(root, manifest)["files"]), 2)
            for invalid in (files[:1], files + files[:1], []):
                manifest.write_text(json.dumps(dict(data, files=invalid)))
                with self.assertRaises(ValueError):
                    lab.verify_corpus(root, manifest)
            manifest.write_text(json.dumps(dict(data, schema_version=2)))
            with self.assertRaises(ValueError):
                lab.verify_corpus(root, manifest)

    def test_synthetic_generator_checks_platform_and_output_scope(self):
        spec = importlib.util.spec_from_file_location("generator", Path(__file__).parents[1] / "generate-corpus.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        with patch.object(generator.sys, "platform", "win32"):
            with self.assertRaisesRegex(ValueError, "macOS"):
                generator.generate(Path("unused"))
        with patch.object(generator.sys, "platform", "darwin"):
            with self.assertRaisesRegex(ValueError, "inside the checkout"):
                generator.generate(generator.ROOT.parent / "outside-corpus")

    def test_swift_probe_is_isolated_and_records_import_adaptation(self):
        spec = importlib.util.spec_from_file_location("prepare", Path(__file__).parents[1] / "prepare-swift-core.py")
        prepare = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(prepare)
        results = lab.ROOT / "tools/windows/results"
        results.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=results) as directory:
            output = Path(directory) / "probe"
            manifest = prepare.prepare(output)
            self.assertFalse(manifest["host_bridge"])
            self.assertEqual(manifest["minimum_tests"], 80)
            self.assertFalse((output / "macos/Sources/LightrayCore/HostProbeClient.swift").exists())
            adapted = [item for item in manifest["files"] if item["source_sha256"] != item["probe_sha256"]]
            self.assertEqual(len(adapted), 5)
            for item in adapted:
                original = (lab.ROOT / item["path"]).read_bytes()
                self.assertEqual(hashlib.sha256(original).hexdigest(), item["source_sha256"])
                self.assertEqual((output / item["path"]).read_bytes(), original.replace(b"import CryptoKit", b"import Crypto"))
            with self.assertRaises(FileExistsError):
                prepare.prepare(output)
            host_output = Path(directory) / "host-probe"
            host_manifest = prepare.prepare(host_output, host_bridge=True)
            self.assertTrue(host_manifest["host_bridge"])
            self.assertEqual(host_manifest["minimum_tests"], 88)
            for name, target in (("host_bridge.swift", "Sources/LightrayCore/HostBridge.swift"), ("host_probe_client.swift", "Sources/LightrayCore/HostProbeClient.swift"), ("host_bridge_tests.swift", "Tests/LightrayCoreTests/HostBridgeTests.swift")):
                original = (lab.ROOT / "tools/windows/src" / name).read_bytes()
                self.assertEqual((host_output / "macos" / target).read_bytes(), original)
                self.assertEqual(host_manifest["other_inputs_sha256"]["tools/windows/src/" + name], hashlib.sha256(original).hexdigest())
        with self.assertRaisesRegex(ValueError, "inside tools/windows/results"):
            prepare.prepare(lab.ROOT / "macos")

    def test_checksum_and_path_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "manifest.json"
            (root / "clip").write_bytes(b"corrupted")
            item = {"path": "clip", "bytes": 9, "sha256": "0" * 64}
            path.write_text(json.dumps({"files": [item]}))
            with self.assertRaisesRegex(ValueError, "checksum"):
                lab.verify_corpus(root, path)
            item["path"] = "../outside"
            path.write_text(json.dumps({"files": [item]}))
            with self.assertRaisesRegex(ValueError, "escapes"):
                lab.verify_corpus(root, path)

    def test_remote_keeps_strict_identity_and_no_shell(self):
        def run(args, **kwargs):
            self.assertIn("StrictHostKeyChecking=yes", args)
            self.assertIn("BatchMode=yes", args)
            self.assertNotIn("shell", kwargs)
            self.assertLessEqual(kwargs["timeout"], 60)
            return subprocess.CompletedProcess(args, 255, "", "Host key verification failed.")
        self.assertEqual(lab.inventory("rtx4090", run)["reason"], "ssh_host_identity_unverified")
        for invalid in ("-oProxyCommand=bad", "host;command", "user@host", "a b"):
            with self.assertRaises(ValueError):
                lab.inventory(invalid, run)

    def test_dedicated_verified_host_file_is_forwarded(self):
        trusted = Path("verified-hosts")
        def run(args, **kwargs):
            self.assertIn("UserKnownHostsFile=" + str(trusted.resolve()), args)
            self.assertIn("StrictHostKeyChecking=yes", args)
            return subprocess.CompletedProcess(args, 255, "", "Permission denied")
        self.assertEqual(lab.inventory("host", run, known_hosts=trusted)["reason"], "ssh_authentication_failed")

    def test_hardware_backend_and_adapter_guards(self):
        with patch.object(lab.sys, "platform", "darwin"):
            for backend in ("d3d11va", "media-foundation"):
                with self.assertRaisesRegex(ValueError, "native Windows"):
                    lab.decode_reference(Path("unused"), "ffmpeg", "ffprobe", backend)
        for index in (-1, 16):
            with self.assertRaisesRegex(ValueError, "adapter index"):
                lab.decode_reference(Path("unused"), "ffmpeg", "ffprobe", adapter_index=index)

    def test_adapter_selection_rejects_missing_software_and_unusable_devices(self):
        hardware = {"index": 0, "software": False, "device_hresult": 0, "hevc_main_profile": True}
        self.assertEqual(lab.select_adapter({"adapters": [hardware]}, 0), hardware)
        with self.assertRaisesRegex(ValueError, "does not exist"):
            lab.select_adapter({"adapters": [hardware]}, 15)
        for field, value in (("software", True), ("device_hresult", -1), ("hevc_main_profile", False)):
            with self.assertRaisesRegex(ValueError, "hardware HEVC"):
                lab.select_adapter({"adapters": [dict(hardware, **{field: value})]}, 0)

    def test_timeout_authentication_and_bad_output(self):
        def timeout(*args, **kwargs):
            raise subprocess.TimeoutExpired("ssh", 45)
        self.assertEqual(lab.inventory("host", timeout)["reason"], "remote_inventory_timeout")
        for code, stdout, stderr, reason in [(255, "", "Permission denied", "ssh_authentication_failed"), (0, "not json", "", "invalid_inventory_json"), (0, "[]", "", "invalid_inventory_schema")]:
            result = lab.inventory("host", lambda *a, **kw: subprocess.CompletedProcess([], code, stdout, stderr))
            self.assertEqual(result["reason"], reason)

    def test_partial_inventory_does_not_pass(self):
        data = {"schema_version": 1, "platform": "windows", "os": {"Version": "test"}}
        run = lambda *a, **kw: subprocess.CompletedProcess([], 0, json.dumps(data), "")
        self.assertEqual(lab.inventory("host", run)["status"], "partial")
        data.update(cpu=[{}], gpu=[{}], ram_bytes=1024)
        self.assertEqual(lab.inventory("host", run)["status"], "collected")

    def test_frame_hash_parser_rejects_empty_and_malformed_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frames"
            for contents in ("# header only", "0, 1, 2", "0, 0, 0, 1, 10, invalid"):
                path.write_text(contents)
                with self.assertRaises(ValueError):
                    lab.frame_hashes(path)
            path.write_text("# comment\n0, 0, 0, 1, 10, " + "a" * 64 + "\n")
            self.assertEqual(lab.frame_hashes(path), [{"bytes": 10, "sha256": "a" * 64}])


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.reference = self.root / "reference"
        self.candidate = self.root / "candidate"
        self.make_run(self.reference, ["a", "b"])
        self.make_run(self.candidate, ["a", "b"])

    def make_run(self, directory, values):
        directory.mkdir(exist_ok=True)
        artifact = directory / "clip.framehash"
        artifact.write_text("# synthetic test data\n" + "".join(f"0, {i}, {i}, 1, 10, {value * 64}\n" for i, value in enumerate(values)))
        data = {"schema_version": 1, "status": "passed", "action": "decode-reference", "run_id": directory.name, "clips": [{"clip": "clip", "input_sha256": "input", "format": {"pix_fmt": "yuv420p"}, "frames": len(values), "framehash_file": artifact.name, "framehash_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest()}]}
        (directory / "result.json").write_text(json.dumps(data))

    def mutate_result(self, change):
        path = self.candidate / "result.json"
        data = json.loads(path.read_text())
        change(data)
        path.write_text(json.dumps(data))

    def test_identical_pixels_and_separate_runs(self):
        self.assertEqual(lab.compare_reference(self.reference, self.candidate)["status"], "passed")
        with self.assertRaisesRegex(ValueError, "separate"):
            lab.compare_reference(self.reference, self.reference)

    def test_changed_pixels_and_missing_frames_fail(self):
        for values, count in [(["a", "c"], 1), (["a"], 1), (["b", "a"], 2)]:
            self.make_run(self.candidate, values)
            result = lab.compare_reference(self.reference, self.candidate)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["clips"][0]["mismatched_frames"], count)

    def test_tampered_artifact_is_rejected(self):
        (self.candidate / "clip.framehash").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "checksum"):
            lab.compare_reference(self.reference, self.candidate)

    def test_unmatched_inputs_and_invalid_manifests_are_rejected(self):
        mutations = [lambda d: d.update(status="failed"), lambda d: d.update(clips=[]), lambda d: d["clips"].append(d["clips"][0]), lambda d: d["clips"][0].update(input_sha256="different"), lambda d: d["clips"][0].update(format={"pix_fmt": "nv12"}), lambda d: d["clips"][0].update(framehash_file="../escape.framehash"), lambda d: d["clips"][0].update(frames=99), lambda d: d["clips"][0].update(clip="other")]
        for mutation in mutations:
            self.make_run(self.candidate, ["a", "b"])
            self.mutate_result(mutation)
            with self.assertRaises(ValueError):
                lab.compare_reference(self.reference, self.candidate)


class PresentationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.one, self.two = self.root / "one", self.root / "two"
        self.make_run(self.one, 1)
        self.make_run(self.two, 2)

    def make_run(self, directory, latency):
        directory.mkdir(exist_ok=True)
        data = {"schema_version": 1, "status": "passed", "maximum_frame_latency": latency, "buffer_width": 1920, "buffer_height": 1080, "frames_submitted": 120, "wall_seconds": 2, "present_calls_per_second": 60, "submit_interval_p50_ms": 16, "submit_interval_p95_ms": 16, "submit_interval_p99_ms": 16, "wait_p95_ms": 15, "present_call_p95_ms": .5}
        (directory / "result.json").write_text(json.dumps(data))
        rows = ["frame,wait_ms,cpu_submit_ms,present_call_ms,submit_interval_ms"]
        rows += [f"{index},15,0.1,0.5,{16 if index else 0}" for index in range(120)]
        (directory / "result.csv").write_text("\n".join(rows) + "\n")

    def test_valid_pair_checks_raw_data_without_choosing_winner(self):
        result = lab.compare_presentation(self.one, self.two)
        self.assertEqual(result["status"], "passed")
        self.assertIsNone(result["winner"])
        self.assertEqual(result["runs"][0]["frames_submitted"], 120)
        with self.assertRaises(ValueError):
            lab.compare_presentation(self.one, self.one)

    def test_missing_reordered_nonfinite_and_malformed_frames_fail(self):
        original = (self.two / "result.csv").read_text()
        for invalid in ("\n".join(original.splitlines()[:-1]), original.replace("1,15,", "0,15,", 1), original.replace("15,0.1", "nan,0.1", 1), original.replace("0,15,0.1,0.5,0", "0,15"), original.replace("1,15,0.1,", "1,15,999,", 1)):
            (self.two / "result.csv").write_text(invalid)
            with self.assertRaises(ValueError):
                lab.compare_presentation(self.one, self.two)

    def test_false_summary_incomplete_run_and_different_workloads_fail(self):
        original = json.loads((self.two / "result.json").read_text())
        for update in ({"status": "failed"}, {"maximum_frame_latency": 1}, {"maximum_frame_latency": True}, {"buffer_width": 2560, "buffer_height": 1440}, {"frames_submitted": 119}, {"submit_interval_p99_ms": 1}, {"wall_seconds": float("nan")}, {"wall_seconds": 31}, {"present_calls_per_second": 1000}):
            (self.two / "result.json").write_text(json.dumps(dict(original, **update)))
            with self.assertRaises(ValueError):
                lab.compare_presentation(self.one, self.two)


if __name__ == "__main__":
    unittest.main()
