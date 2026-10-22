"""Independent fixed-point reference for the FPGA's 16-character demo prompt.

The NPU supplies signed INT32 matrix-vector sums. RV32I applies the exported
biases, Q4.4 scaling, attention weighted sum, GELU table, and residuals.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

PROMPT = "THE SMALL FPGA L"
ACT_SHIFT = -4


def clamp(value: np.ndarray | int) -> np.ndarray:
    return np.clip(value, -128, 127).astype(np.int64)


def load_model(root: Path) -> tuple[dict, dict[str, np.ndarray]]:
    manifest = json.loads((root / "manifest.json").read_text(encoding="ascii"))
    tensors = {}
    for name, metadata in manifest["tensors"].items():
        path = root / metadata["file"]
        values = [int(line, 16) for line in path.read_text(encoding="ascii").splitlines()]
        expected = math.prod(metadata["shape"])
        if len(values) != expected or any(v < 0 or v > 255 for v in values):
            raise ValueError(f"invalid exported tensor {name}")
        tensors[name] = np.array([v - 256 if v >= 128 else v for v in values],
                                 dtype=np.int64).reshape(metadata["shape"])
    return manifest, tensors


def infer(root: Path = Path("model_hex"), include_trace: bool = False) -> dict:
    manifest, tensor = load_model(root)
    shifts = {name: info["scale_shift"] for name, info in manifest["tensors"].items()}
    if len(PROMPT) != 16:
        raise ValueError("the demo prompt must fill the context")

    def dense(name: str, x: np.ndarray) -> np.ndarray:
        raw = tensor["W_" + name] @ x
        product_shift = ACT_SHIFT + shifts["W_" + name]
        bias_shift = shifts["B_" + name] - product_shift
        bias_raw = (tensor["B_" + name] * (1 << bias_shift) if bias_shift >= 0
                    else tensor["B_" + name] >> -bias_shift)
        biased = raw + bias_raw
        output_shift = product_shift - ACT_SHIFT
        return clamp(biased * (1 << output_shift) if output_shift >= 0
                     else biased >> -output_shift)

    ids = [ord(symbol) - 32 for symbol in PROMPT]
    def to_q4_4(values: np.ndarray, scale_shift: int) -> np.ndarray:
        delta = scale_shift - ACT_SHIFT
        return values * (1 << delta) if delta >= 0 else values >> -delta

    hidden = clamp(to_q4_4(tensor["TOKEN_EMBEDDING"][ids], shifts["TOKEN_EMBEDDING"])
                   + to_q4_4(tensor["POSITION_EMBEDDING"], shifts["POSITION_EMBEDDING"]))
    keys = np.stack([dense("K", x) for x in hidden])
    values = np.stack([dense("V", x) for x in hidden])
    query = dense("Q", hidden[-1])
    scores = clamp((keys @ query) >> 6)

    # This follows the RTL's 64-entry exp(-delta/16) table and Q0.16 divide.
    maximum = int(scores.max())
    index = np.clip(maximum - scores, 0, 63)
    numerator = np.array([round(65535 * math.exp(-int(i) / 16)) for i in index],
                         dtype=np.int64)
    probability = (numerator * 65535) // int(numerator.sum())
    context = clamp((probability @ values) >> 16)
    projected = dense("O", context)
    attended = clamp(hidden[-1] + projected)

    ff_before_gelu = dense("FF1", attended)
    gelu_table = np.array([
        max(-128, min(127, round((x / 16) * 0.5
                * (1 + math.erf((x / 16) / math.sqrt(2))) * 16)))
        for x in range(-128, 128)
    ], dtype=np.int64)
    ff = gelu_table[ff_before_gelu + 128]
    final_hidden = clamp(attended + dense("FF2", ff))
    raw_logits = tensor["W_VOCAB"] @ final_hidden
    product_shift = ACT_SHIFT + shifts["W_VOCAB"]
    bias_raw = tensor["B_VOCAB"] * (1 << (shifts["B_VOCAB"] - product_shift))
    logits = raw_logits + bias_raw
    token = int(np.argmax(logits))
    result = {
        "prompt": PROMPT,
        "token_id": token,
        "character": chr(token + 32),
        "scores": scores.tolist(),
        "probability_q16": probability.tolist(),
        "hidden_q4_4": final_hidden.tolist(),
        "logit_raw": int(logits[token]),
    }
    if include_trace:
        result["trace"] = {
            1: hidden[-1].tolist(), 2: query.tolist(), 3: keys[12].tolist(),
            4: values[12].tolist(), 5: scores.tolist(),
            6: probability.tolist(), 7: context.tolist(),
            8: projected.tolist(), 9: attended.tolist(),
            10: ff_before_gelu.tolist(), 11: ff.tolist(),
            12: final_hidden.tolist(),
        }
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, default=Path("model_hex"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = infer(args.model_dir)
    payload = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(payload, encoding="ascii")
    print(payload, end="")


if __name__ == "__main__":
    main()
