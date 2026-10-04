#!/usr/bin/env python3
"""Reconcile sampled client telemetry with one native host process's CSV."""
import argparse
import csv
import json
from pathlib import Path
import re

SAMPLE = re.compile(r"host sample (\d+) capture_us (\d+) encode_us (\d+)")


def reconcile(csv_path: Path, log_path: Path) -> dict:
    rows = {}
    with csv_path.open(newline='', encoding='utf-8-sig') as source:
        for row in csv.DictReader(source):
            sample = int(row['sample_id'])
            if sample in rows:
                raise ValueError('Duplicate host sample ID; use a CSV from one process')
            rows[sample] = (int(row['capture_us']), int(row['encode_us']))
    samples = SAMPLE.findall(log_path.read_text(encoding='utf-8'))
    if not samples:
        raise ValueError('No client host-timing samples found')
    mismatches = []
    for sample, capture, encode in samples:
        expected = rows.get(int(sample))
        if expected != (int(capture), int(encode)):
            mismatches.append(int(sample))
    return {'status': 'passed' if not mismatches else 'failed', 'host_rows': len(rows), 'client_samples': len(samples), 'mismatched_sample_ids': mismatches, 'scope': 'Exact sampled durations, not every frame and not end-to-end latency'}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host-csv', required=True, type=Path)
    parser.add_argument('--client-log', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = reconcile(args.host_csv, args.client_log)
    except (ValueError, KeyError, OSError) as error:
        result = {'status': 'failed', 'error': str(error)}
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
