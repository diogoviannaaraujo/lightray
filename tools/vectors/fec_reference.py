"""Generate an independent, small GF(256) Vandermonde oracle for the provisional FEC profile."""

import argparse
import json
from pathlib import Path


def multiply(left: int, right: int) -> int:
    result = 0
    while right:
        if right & 1:
            result ^= left
        right >>= 1
        left <<= 1
        if left & 0x100:
            left ^= 0x11D
    return result


def power(value: int, exponent: int) -> int:
    result = 1
    while exponent:
        if exponent & 1:
            result = multiply(result, value)
        value = multiply(value, value)
        exponent >>= 1
    return result


def invert(matrix: list[list[int]]) -> list[list[int]]:
    size = len(matrix)
    rows = [row[:] + [int(i == j) for j in range(size)] for i, row in enumerate(matrix)]
    for column in range(size):
        pivot = next((i for i in range(column, size) if rows[i][column]), None)
        if pivot is None:
            raise ValueError("Singular GF(256) matrix")
        rows[column], rows[pivot] = rows[pivot], rows[column]
        factor = power(rows[column][column], 254)
        rows[column] = [multiply(value, factor) for value in rows[column]]
        for index in range(size):
            if index != column:
                factor = rows[index][column]
                rows[index] = [value ^ multiply(factor, other) for value, other in zip(rows[index], rows[column])]
    return [row[size:] for row in rows]


def dot(left: list[int], right: list[int]) -> int:
    result = 0
    for a, b in zip(left, right):
        result ^= multiply(a, b)
    return result


def fixture(k: int, p: int, length: int, last_length: int) -> dict:
    vandermonde = [[power(2, row * column) for column in range(k)] for row in range(k)]
    inverse = invert(vandermonde)
    coefficients = [[dot(inverse[row], [power(2, column * degree) for degree in range(k)]) for row in range(k)] for column in range(k, k + p)]
    data = [[(index * 37 + offset * 13) & 255 for offset in range(length)] for index in range(k)]
    data[-1][last_length:] = [0] * (length - last_length)
    parity = [[dot(row, [shard[offset] for shard in data]) for offset in range(length)] for row in coefficients]
    return {"k": k, "p": p, "stride": length, "last_length": last_length, "coefficients": coefficients, "data": data, "parity": parity}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", type=Path, help="Verify an existing fixture without changing it")
    parser.add_argument("--output", type=Path, help="Write the generated fixture")
    args = parser.parse_args()
    if args.check and args.output:
        parser.error("Choose --check or --output")
    result = {"schema_version": 1, "polynomial": 0x11D, "primitive_element": 2, "cases": [fixture(1, 1, 8, 3), fixture(3, 2, 8, 5), fixture(7, 4, 8, 8)]}
    if args.check:
        if json.loads(args.check.read_text()) != result:
            raise SystemExit("FEC reference fixture differs from the independent generator")
        print("3 FEC reference cases verified")
    elif args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    else:
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
