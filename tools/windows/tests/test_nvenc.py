import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('nvenc', Path(__file__).parents[1] / 'run-nvenc-probe.py')
nvenc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nvenc)


def pack(items):
    return b''.join(len(item).to_bytes(4, 'big') + item for item in items)


def fixture():
    payloads, configs, rows = [], [], []
    for i in range(120):
        idr = i in (0, 60)
        sets = [bytes([kind << 1, 1, 128]) for kind in (32, 33, 34)] if idr else []
        payload = pack(sets + [bytes([38 if idr else 2, 1, 128])])
        config = pack(sets)
        payloads.append(payload)
        configs.append(config)
        rows.append({'frame': str(i), 'output_timestamp': str(i), 'idr': str(int(idr)), 'annexb_bytes': '30', 'payload_bytes': str(len(payload)), 'config_bytes': str(len(config)), 'encode_and_lock_ms': '0.5'})
    return payloads, configs, rows


class NvencTests(unittest.TestCase):
    def test_mac_interop_uses_unmodified_reference_copies(self):
        spec = importlib.util.spec_from_file_location('prepare_interop', Path(__file__).parents[1] / 'prepare-nvenc-mac-interop.py')
        prepare = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(prepare)
        results = nvenc.ROOT / 'tools/windows/results'
        results.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=results) as directory:
            output = Path(directory) / 'interop'
            prepare.prepare(output)
            self.assertEqual((output / 'Sources/LightrayMac/VideoDecoder.swift').read_bytes(), (nvenc.ROOT / 'macos/Sources/LightrayMac/VideoDecoder.swift').read_bytes())
            self.assertEqual((output / 'Sources/LightrayCore/Media/VideoSender.swift').read_bytes(), (nvenc.ROOT / 'macos/Sources/LightrayCore/Media/VideoSender.swift').read_bytes())
            with self.assertRaises(FileExistsError):
                prepare.prepare(output)
        with self.assertRaises(ValueError):
            prepare.prepare(nvenc.ROOT / 'macos')

    def test_complete_framing_and_recovery_config(self):
        payloads, configs, rows = fixture()
        rebuilt = nvenc.verify_records(pack(payloads), pack(configs), rows)
        self.assertEqual(rebuilt.count(b'\0\0\0\1'), 126)
        self.assertTrue(rebuilt.startswith(b'\0\0\0\1\x40\x01\x80'))

    def test_truncated_or_oversized_records_fail(self):
        for invalid in (b'\0', b'\0\0\0\x05hi', b'\xff\xff\xff\xff'):
            with self.assertRaises(ValueError):
                nvenc.records(invalid)

    def test_partial_reordered_or_nonfinite_measurements_fail(self):
        for field, value in (('frame', '1'), ('output_timestamp', '1'), ('idr', '0'), ('payload_bytes', '1'), ('config_bytes', '1'), ('annexb_bytes', '0'), ('encode_and_lock_ms', 'nan'), ('encode_and_lock_ms', '-1')):
            with self.subTest(field=field, value=value):
                payloads, configs, rows = fixture()
                rows[0][field] = value
                with self.assertRaises(ValueError):
                    nvenc.verify_records(pack(payloads), pack(configs), rows)
        payloads, configs, rows = fixture()
        with self.assertRaises(ValueError):
            nvenc.verify_records(pack(payloads[:-1]), pack(configs), rows)

    def test_parameter_set_corruption_or_wrong_idr_fails(self):
        for case in ('config', 'nal_header', 'idr_missing', 'unexpected_idr'):
            payloads, configs, rows = fixture()
            if case == 'config':
                configs[0] = configs[0][:-1] + b'\x81'
            elif case == 'nal_header':
                payloads[1] = pack([b'\x02\x00\x80'])
            elif case == 'idr_missing':
                payloads[0] = payloads[1]
            else:
                payloads[1] = payloads[0]
            with self.subTest(case=case), self.assertRaises(ValueError):
                nvenc.verify_records(pack(payloads), pack(configs), rows)


if __name__ == '__main__':
    unittest.main()
