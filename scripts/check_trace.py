"""Compare optional SoC layer traces with the independent fixed-point model."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from quantized_transformer import infer  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--model-dir", type=Path, default=Path("model_hex"))
    args = parser.parse_args()
    actual: dict[int, dict[int, int]] = {}
    for line in args.log.read_text(errors="replace").splitlines():
        match = re.search(r"TRACE (\d+) (\d+) (-?\d+)", line)
        if match:
            stage, index, value = map(int, match.groups())
            actual.setdefault(stage, {})[index] = value & 0xFFFF if stage == 6 else value
    expected = infer(args.model_dir, include_trace=True)["trace"]
    for stage, vector in expected.items():
        observed = [actual.get(stage, {}).get(i) for i in range(len(vector))]
        if observed != vector:
            mismatch = next(i for i, (a, b) in enumerate(zip(observed, vector)) if a != b)
            raise AssertionError(f"stage {stage}, index {mismatch}: RTL={observed[mismatch]}, reference={vector[mismatch]}")
    print(f"PASS: all {len(expected)} traced stages match the fixed-point reference")


if __name__ == "__main__":
    main()
