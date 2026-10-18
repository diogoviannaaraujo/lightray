#!/usr/bin/env python3
"""Wait for Apple's processing to finish and verify internal TestFlight availability.

Uses the same App Store Connect API key as altool; only Python's standard library and
OpenSSL are required. Never prints credentials or JWTs.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode()


def token(key):
    now = int(time.time())
    header = {'alg': 'ES256', 'kid': os.environ['API_KEY_ID'], 'typ': 'JWT'}
    payload = {'iss': os.environ['API_ISSUER_ID'], 'iat': now - 10,
               'exp': now + 600, 'aud': 'appstoreconnect-v1'}
    message = '.'.join(b64(json.dumps(part).encode()) for part in (header, payload))
    der = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(key)],
                         input=message.encode(), capture_output=True, check=True).stdout
    # OpenSSL emits a DER SEQUENCE of INTEGER r and s. JWT requires two fixed-width integers.
    if der[:1] != b'\x30' or der[2:3] != b'\x02':
        raise ValueError('Unexpected ECDSA signature')
    size = der[3]
    r = int.from_bytes(der[4:4 + size], 'big').to_bytes(32, 'big')
    offset = 4 + size
    if der[offset] != 2:
        raise ValueError('Unexpected ECDSA signature')
    s = int.from_bytes(der[offset + 2:offset + 2 + der[offset + 1]], 'big').to_bytes(32, 'big')
    return message + '.' + b64(r + s)


def request(key, path, query=None):
    url = 'https://api.appstoreconnect.apple.com/v1/' + path
    if query:
        url += '?' + urlencode(query)
    req = Request(url, headers={'Authorization': 'Bearer ' + token(key)})
    try:
        with urlopen(req, timeout=60) as response:
            return json.load(response)
    except HTTPError as error:
        if error.code == 429 or error.code >= 500:
            print(f'App Store Connect returned HTTP {error.code}; retrying.', flush=True)
            return None
        raise RuntimeError(f'App Store Connect HTTP {error.code}: {error.read().decode()}') from error
    except (URLError, TimeoutError):
        print('App Store Connect connection failed; retrying.', flush=True)
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['IOS', 'MAC_OS'], required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--bundle-id', default='com.getlightray.client')
    parser.add_argument('--timeout', type=int, default=1800)
    args = parser.parse_args()
    apps = request(args.key, 'apps', {'filter[bundleId]': args.bundle_id})
    if not apps or len(apps['data']) != 1:
        raise RuntimeError('Expected one App Store Connect app for ' + args.bundle_id)
    app = apps['data'][0]['id']
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        result = request(args.key, 'builds', {
            'filter[app]': app, 'filter[version]': args.build_number,
            'filter[preReleaseVersion.platform]': args.platform,
            'filter[preReleaseVersion.version]': args.version,
            'include': 'buildBetaDetail',
        })
        if result and result['data']:
            build = result['data'][0]
            state = build['attributes']['processingState']
            details = next((item['attributes'] for item in result.get('included', [])
                            if item['type'] == 'buildBetaDetails'), {})
            internal = details.get('internalBuildState', 'UNKNOWN')
            print(f'{args.platform} {args.version} ({args.build_number}): {state}, {internal}', flush=True)
            if state in ('FAILED', 'INVALID') or internal in ('FAILED', 'EXPIRED', 'MISSING_EXPORT_COMPLIANCE'):
                raise RuntimeError('Apple rejected the build or requires export compliance')
            if state == 'VALID' and internal == 'IN_BETA_TESTING':
                print(f'TestFlight ready: https://appstoreconnect.apple.com/apps/{app}/testflight', flush=True)
                return
        else:
            print('Waiting for the uploaded build to appear in App Store Connect.', flush=True)
        time.sleep(min(30, max(0, deadline - time.monotonic())))
    raise TimeoutError('Apple has not made the build available in TestFlight within the processing timeout')


if __name__ == '__main__':
    main()
