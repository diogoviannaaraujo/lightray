import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('testflight_status', Path(__file__).parents[1] / 'testflight-status.py')
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)


class TestFlightStatusTests(unittest.TestCase):
    def test_jwt_signature_verifies_with_openssl(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / 'key.pem'
            subprocess.run(['openssl', 'ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', key], check=True)
            public = subprocess.check_output(['openssl', 'pkey', '-in', key, '-pubout'])
            public_path = Path(directory) / 'public.pem'
            public_path.write_bytes(public)
            with patch.dict(os.environ, API_KEY_ID='TESTKEY', API_ISSUER_ID='test-issuer'):
                encoded = status.token(key)
            header, payload, signature = encoded.split('.')
            self.assertEqual(json.loads(base64.urlsafe_b64decode(header + '=='))['alg'], 'ES256')
            self.assertEqual(json.loads(base64.urlsafe_b64decode(payload + '=='))['aud'], 'appstoreconnect-v1')
            raw = base64.urlsafe_b64decode(signature + '==')
            self.assertEqual(len(raw), 64)
            def integer(part):
                value = part.lstrip(b'\x00') or b'\x00'
                if value[0] & 128:
                    value = b'\x00' + value
                return bytes([2, len(value)]) + value
            body = integer(raw[:32]) + integer(raw[32:])
            signature_path = Path(directory) / 'signature.der'
            signature_path.write_bytes(bytes([48, len(body)]) + body)
            subprocess.run(['openssl', 'dgst', '-sha256', '-verify', public_path, '-signature', signature_path],
                           input=(header + '.' + payload).encode(), check=True, capture_output=True)

    def run_processing(self, processing, internal):
        responses = [
            {'data': [{'id': 'app'}]},
            {'data': [{'id': 'build', 'attributes': {'processingState': processing}}],
             'included': [{'type': 'buildBetaDetails', 'attributes': {'internalBuildState': internal}}]},
        ]
        argv = ['testflight-status.py', '--platform', 'MAC_OS', '--version', '0.1.0',
                '--build-number', '5.1', '--key', '/unused']
        with patch('sys.argv', argv), patch.object(status, 'request', side_effect=responses):
            status.main()

    def test_processed_and_distributed_build_succeeds(self):
        self.run_processing('VALID', 'IN_BETA_TESTING')

    def test_invalid_upload_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'Apple rejected'):
            self.run_processing('INVALID', 'PROCESSING_EXCEPTION')

    def test_missing_compliance_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'export compliance'):
            self.run_processing('VALID', 'MISSING_EXPORT_COMPLIANCE')

    def test_processing_timeout_does_not_report_success(self):
        argv = ['testflight-status.py', '--platform', 'IOS', '--version', '0.1.0',
                '--build-number', '5.1', '--key', '/unused', '--timeout', '0']
        with patch('sys.argv', argv), patch.object(status, 'request', return_value={'data': [{'id': 'app'}]}):
            with self.assertRaises(TimeoutError):
                status.main()


if __name__ == '__main__':
    unittest.main()
