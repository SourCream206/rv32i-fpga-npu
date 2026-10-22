"""Convert little-endian RV32I binary bytes to 32-bit $readmemh words."""

from __future__ import annotations

import argparse
from pathlib import Path


def convert(source: Path, destination: Path, limit: int = 16 * 1024) -> None:
    data = source.read_bytes()
    if not data or len(data) > limit:
        raise ValueError(f"firmware image has {len(data)} bytes; expected 1..{limit}")
    data += bytes(limit - len(data))
    lines = [f"{int.from_bytes(data[i:i + 4], 'little'):08x}"
             for i in range(0, len(data), 4)]
    destination.write_text("\n".join(lines) + "\n", encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    convert(args.source, args.destination)


if __name__ == "__main__":
    main()
