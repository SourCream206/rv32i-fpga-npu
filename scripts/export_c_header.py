"""Convert model_hex INT8 $readmemh files into RV32I C arrays."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def c_name(path: Path) -> str:
    return "MODEL_" + "".join(
        character if character.isalnum() else "_"
        for character in path.stem.upper()
    )


def values_from_hex(path: Path) -> list[int]:
    values = []
    for line in path.read_text(encoding="ascii").splitlines():
        value = int(line, 16)
        if not 0 <= value <= 0xFF:
            raise ValueError(f"{path}: value outside one-byte INT8 encoding")
        values.append(value - 256 if value >= 128 else value)
    if not values:
        raise ValueError(f"{path}: no weights")
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, default=Path("model_hex"))
    parser.add_argument("--output", type=Path, default=Path("software/model_weights.h"))
    args = parser.parse_args()

    manifest_path = args.model_dir / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"missing {manifest_path}; run train_and_export.py first")
    manifest = json.loads(manifest_path.read_text(encoding="ascii"))
    tensors = manifest["tensors"]
    lines = [
        "#ifndef MODEL_WEIGHTS_H",
        "#define MODEL_WEIGHTS_H",
        "",
        "#include <stdint.h>",
        "",
    ]
    for name, metadata in tensors.items():
        path = args.model_dir / metadata["file"]
        values = values_from_hex(path)
        expected_count = 1
        for dimension in metadata["shape"]:
            expected_count *= dimension
        if len(values) != expected_count:
            raise ValueError(f"{path}: expected {expected_count} values, got {len(values)}")
        symbol = c_name(path)
        lines.append(f"/* {name}: shape {metadata['shape']}, row-major [output][input]. */")
        lines.append(f"static const int8_t {symbol}[{len(values)}] = {{")
        for offset in range(0, len(values), 16):
            lines.append("    " + ", ".join(str(value) for value in values[offset : offset + 16]) + ",")
        lines.extend(["};", ""])
    lines.append("#endif")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"Wrote {args.output} from {len(tensors)} INT8 tensors")


if __name__ == "__main__":
    main()
