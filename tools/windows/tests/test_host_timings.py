import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('host_timings', Path(__file__).parents[1] / 'verify-host-timings.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class HostTimingsTests(unittest.TestCase):
    def test_exact_samples_and_mismatches(self):
        with tempfile.TemporaryDirectory() as directory:
            csv = Path(directory) / 'host.csv'
            log = Path(directory) / 'client.log'
            csv.write_text('sample_id,capture_us,encode_us\n1,1200,3000\n2,2400,6000\n')
            log.write_text('host sample 2 capture_us 2400 encode_us 6000')
            self.assertEqual(module.reconcile(csv, log)['status'], 'passed')
            for text in ['host sample 2 capture_us 2401 encode_us 6000', 'host sample 2 capture_us 2400 encode_us 6001', 'host sample 3 capture_us 2400 encode_us 6000']:
                log.write_text(text)
                self.assertEqual(module.reconcile(csv, log)['status'], 'failed')

    def test_missing_samples_and_duplicate_ids_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            csv = Path(directory) / 'host.csv'
            log = Path(directory) / 'client.log'
            csv.write_text('sample_id,capture_us,encode_us\n1,2,3\n')
            log.write_text('legacy client')
            with self.assertRaises(ValueError):
                module.reconcile(csv, log)
            log.write_text('host sample 1 capture_us 2 encode_us 3')
            csv.write_text('sample_id,capture_us,encode_us\n1,2,3\n1,2,3\n')
            with self.assertRaises(ValueError):
                module.reconcile(csv, log)
