"""Generate the fixed Q4.4 GELU lookup table used by RV32I firmware."""

from __future__ import annotations

import argparse
import math
from pathlib import Path


def gelu_q4_4(value: int) -> int:
    x = value / 16.0
    result = x * 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))
    return max(-128, min(127, round(result * 16.0)))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("software/gelu_lut.h"))
    args = parser.parse_args()
    values = [gelu_q4_4(code if code < 128 else code - 256) for code in range(256)]
    lines = ["#ifndef GELU_LUT_H", "#define GELU_LUT_H", "", "#include <stdint.h>",
             "/* Input and output use signed Q4.4, indexed by the input byte. */",
             "static const int8_t MODEL_GELU_LUT[256] = {"]
    for offset in range(0, 256, 16):
        lines.append("    " + ", ".join(str(v) for v in values[offset:offset + 16]) + ",")
    lines.extend(["};", "", "#endif", ""])
    args.output.write_text("\n".join(lines), encoding="ascii")


if __name__ == "__main__":
    main()
