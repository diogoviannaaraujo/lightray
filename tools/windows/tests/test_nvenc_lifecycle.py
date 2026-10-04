import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('lifecycle', Path(__file__).parents[1] / 'run-nvenc-lifecycle.py')
lifecycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifecycle)


def frames():
    rows, decoded = [], []
    for index in range(600):
        cycle, offset = divmod(index, 6)
        width, height = lifecycle.SIZES[(cycle + (offset >= 4)) % 3]
        generation = 1 if offset < 3 else 2 if offset == 3 else 4 if cycle % 2 == 0 else 3
        idr = offset in (0, 2, 3, 4)
        rows.append(dict(frame=index, cycle=cycle, width=width, height=height, generation=generation, timestamp=offset, idr=int(idr), encode_and_lock_ms=1.0))
        decoded.append(dict(width=width, height=height, pict_type='I' if idr else 'P', pix_fmt='yuv420p'))
    return rows, decoded


def resources():
    return [dict(cycle=i, private_bytes=64 << 20, working_set_bytes=80 << 20, gpu_local_bytes=32 << 20, gpu_nonlocal_bytes=0, handles=40) for i in range(-31, 100)]


class LifecycleTests(unittest.TestCase):
    def test_complete_decode_and_lifecycle_sequence(self):
        rows, decoded = frames()
        self.assertEqual(lifecycle.verify_frames(rows, decoded)['frames'], 600)
        self.assertEqual(lifecycle.verify_frames(rows, decoded)['idr_frames'], 400)

    def test_missing_or_wrong_resolution_generation_picture_fails(self):
        rows, decoded = frames()
        with self.assertRaises(ValueError):
            lifecycle.verify_frames(rows[:-1], decoded)
        for field, value in [('width', 640), ('generation', 999), ('timestamp', 100), ('idr', 0), ('encode_and_lock_ms', float('nan'))]:
            rows, decoded = frames()
            rows[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                lifecycle.verify_frames(rows, decoded)
        for field, value in [('width', 640), ('pict_type', 'B'), ('pix_fmt', 'yuv420p10le')]:
            rows, decoded = frames()
            decoded[4][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                lifecycle.verify_frames(rows, decoded)

    def test_resource_trends_enforce_declared_limits(self):
        self.assertEqual(lifecycle.verify_resources(resources())['handles']['growth'], 0)
        for key, limit in lifecycle.GROWTH_LIMITS.items():
            rows = resources()
            for row in rows[-20:]:
                row[key] += limit + 1
            with self.subTest(key=key), self.assertRaises(ValueError):
                lifecycle.verify_resources(rows)

    def test_partial_reordered_or_negative_resource_samples_fail(self):
        for case in ('missing', 'order', 'negative'):
            rows = resources()
            if case == 'missing':
                rows.pop()
            elif case == 'order':
                rows[50]['cycle'] = 48
            else:
                rows[0]['gpu_local_bytes'] = -1
            with self.subTest(case=case), self.assertRaises(ValueError):
                lifecycle.verify_resources(rows)


if __name__ == '__main__':
    unittest.main()
