"""Train and export a 64-token, one-layer character Transformer for the FPGA NPU.

Each .hex file contains one signed INT8 two's-complement value per line in
row-major order. Matrix dimensions are [output][input], matching the NPU MAC
array's weight[row][column] layout.
"""

from __future__ import annotations

import argparse
import json
import math
import random
from dataclasses import dataclass
from pathlib import Path

import torch
import torch.nn.functional as functional
from torch import Tensor, nn

N_VOCAB = 64
D_MODEL = 16
L_SEQ = 16
D_FF = 32
DEFAULT_CORPUS = """
the small fpga learns one character at a time. the rv32i cpu sends tokens to
the npu. attention finds useful context. the feed forward network refines each
hidden state. hardware and software agree on every integer result.
""".upper()


@dataclass(frozen=True)
class QuantizedTensor:
    values: Tensor
    scale_shift: int


class MicroTransformer(nn.Module):
    """One single-head causal decoder block without LayerNorm."""

    def __init__(self) -> None:
        super().__init__()
        self.token_embedding = nn.Embedding(N_VOCAB, D_MODEL)
        self.position_embedding = nn.Embedding(L_SEQ, D_MODEL)
        self.w_q = nn.Linear(D_MODEL, D_MODEL)
        self.w_k = nn.Linear(D_MODEL, D_MODEL)
        self.w_v = nn.Linear(D_MODEL, D_MODEL)
        self.w_o = nn.Linear(D_MODEL, D_MODEL)
        self.w_ff1 = nn.Linear(D_MODEL, D_FF)
        self.w_ff2 = nn.Linear(D_FF, D_MODEL)
        self.w_vocab = nn.Linear(D_MODEL, N_VOCAB)

    def forward(self, tokens: Tensor, collect_activations: bool = False):
        _, sequence_length = tokens.shape
        positions = torch.arange(sequence_length, device=tokens.device)
        hidden = self.token_embedding(tokens) + self.position_embedding(positions)

        query = self.w_q(hidden)
        key = self.w_k(hidden)
        value = self.w_v(hidden)
        attention_scores = query @ key.transpose(-2, -1) / math.sqrt(D_MODEL)
        causal_mask = torch.triu(
            torch.ones(sequence_length, sequence_length, device=tokens.device, dtype=torch.bool),
            diagonal=1,
        )
        attention_scores = attention_scores.masked_fill(causal_mask, float("-inf"))
        attention = functional.softmax(attention_scores, dim=-1)
        hidden = hidden + self.w_o(attention @ value)

        ffn_hidden = functional.gelu(self.w_ff1(hidden))
        hidden = hidden + self.w_ff2(ffn_hidden)
        logits = self.w_vocab(hidden)

        if collect_activations:
            return logits, {"attention_scores": attention_scores, "ffn_hidden": ffn_hidden}
        return logits


def vocabulary() -> str:
    """Return ASCII code points 0x20 through 0x5F, exactly 64 symbols."""

    symbols = "".join(chr(code_point) for code_point in range(0x20, 0x60))
    assert len(symbols) == N_VOCAB
    return symbols


def encode_corpus(corpus: str, symbols: str) -> Tensor:
    lookup = {symbol: index for index, symbol in enumerate(symbols)}
    normalized = " ".join(corpus.split()).upper()
    unsupported = sorted(set(normalized) - set(symbols))
    if unsupported:
        raise ValueError(f"corpus has characters outside vocabulary: {unsupported!r}")
    if len(normalized) <= L_SEQ:
        raise ValueError(f"corpus must contain more than {L_SEQ} characters")
    return torch.tensor([lookup[character] for character in normalized], dtype=torch.long)


def sample_batch(tokens: Tensor, batch_size: int, generator: torch.Generator) -> tuple[Tensor, Tensor]:
    starts = torch.randint(0, len(tokens) - L_SEQ, (batch_size,), generator=generator)
    inputs = torch.stack([tokens[start : start + L_SEQ] for start in starts])
    targets = torch.stack([tokens[start + 1 : start + L_SEQ + 1] for start in starts])
    return inputs, targets


def nearest_power_of_two_symmetric_int8(values: Tensor) -> QuantizedTensor:
    """Quantize with scale=2**scale_shift and signed range [-127, 127]."""

    maximum = float(values.detach().abs().max())
    if maximum == 0.0:
        return QuantizedTensor(torch.zeros_like(values, dtype=torch.int8), 0)
    scale_shift = math.ceil(math.log2(maximum / 127.0))
    scale = 2.0**scale_shift
    quantized = torch.round(values.detach() / scale).clamp(-127, 127).to(torch.int8)
    return QuantizedTensor(quantized, scale_shift)


def write_readmemh(path: Path, values: Tensor) -> None:
    path.write_text(
        "".join(f"{int(value) & 0xFF:02x}\n" for value in values.flatten().cpu()),
        encoding="ascii",
    )


def c_identifier(name: str) -> str:
    return "".join(character.upper() if character.isalnum() else "_" for character in name)


def parameter_exports(model: MicroTransformer) -> dict[str, Tensor]:
    return {
        "TOKEN_EMBEDDING": model.token_embedding.weight,
        "POSITION_EMBEDDING": model.position_embedding.weight,
        "W_Q": model.w_q.weight,
        "B_Q": model.w_q.bias,
        "W_K": model.w_k.weight,
        "B_K": model.w_k.bias,
        "W_V": model.w_v.weight,
        "B_V": model.w_v.bias,
        "W_O": model.w_o.weight,
        "B_O": model.w_o.bias,
        "W_FF1": model.w_ff1.weight,
        "B_FF1": model.w_ff1.bias,
        "W_FF2": model.w_ff2.weight,
        "B_FF2": model.w_ff2.bias,
        "W_VOCAB": model.w_vocab.weight,
        "B_VOCAB": model.w_vocab.bias,
    }


def calibrated_activation_shifts(model: MicroTransformer, tokens: Tensor) -> dict[str, int]:
    """Return power-of-two scales for activation quantization in fixed-point RTL."""

    model.eval()
    with torch.inference_mode():
        _, activations = model(tokens.unsqueeze(0), collect_activations=True)
    valid_scores = activations["attention_scores"][torch.isfinite(activations["attention_scores"])]
    return {
        "FFN_ACTIVATION": nearest_power_of_two_symmetric_int8(activations["ffn_hidden"]).scale_shift,
        "SOFTMAX_INPUT": nearest_power_of_two_symmetric_int8(valid_scores).scale_shift,
    }


def write_quantization_header(
    path: Path,
    parameters: dict[str, QuantizedTensor],
    activation_shifts: dict[str, int],
) -> None:
    lines = [
        "#ifndef QUANTIZATION_CONFIG_H",
        "#define QUANTIZATION_CONFIG_H",
        "",
        f"#define NPU_VOCAB_SIZE {N_VOCAB}",
        f"#define NPU_D_MODEL {D_MODEL}",
        f"#define NPU_CONTEXT_LENGTH {L_SEQ}",
        f"#define NPU_D_FF {D_FF}",
        "#define NPU_ATTENTION_HEADS 1",
        "#define NPU_ATTENTION_DK_SHIFT 2",
        "#define NPU_SHIFT_Q (-NPU_W_Q_SCALE_SHIFT)",
        "#define NPU_SHIFT_K (-NPU_W_K_SCALE_SHIFT)",
        "#define NPU_SHIFT_V (-NPU_W_V_SCALE_SHIFT)",
        "#define NPU_SHIFT_O (-NPU_W_O_SCALE_SHIFT)",
        "#define NPU_SHIFT_FF1 (-NPU_W_FF1_SCALE_SHIFT)",
        "#define NPU_SHIFT_FF2 (-NPU_W_FF2_SCALE_SHIFT)",
        "#define NPU_SHIFT_VOCAB (-NPU_W_VOCAB_SCALE_SHIFT)",
        f"#define NPU_FFN_SCALING_SHIFT {activation_shifts['FFN_ACTIVATION']}",
        f"#define NPU_FFN_ACTIVATION_SHIFT {activation_shifts['FFN_ACTIVATION']}",
        f"#define NPU_SOFTMAX_INPUT_SHIFT {activation_shifts['SOFTMAX_INPUT']}",
        "",
        "/* Dequantized value = int8_value * 2^(NPU_<NAME>_SCALE_SHIFT). */",
    ]
    for name, quantized in parameters.items():
        lines.append(f"#define NPU_{c_identifier(name)}_SCALE_SHIFT {quantized.scale_shift}")
    lines.extend(["", "#endif"])
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def train(
    model: MicroTransformer,
    tokens: Tensor,
    steps: int,
    batch_size: int,
    learning_rate: float,
    target_loss: float,
    generator: torch.Generator,
) -> tuple[int, float]:
    optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate)
    model.train()
    for step in range(1, steps + 1):
        inputs, targets = sample_batch(tokens, batch_size, generator)
        logits = model(inputs)
        loss = functional.cross_entropy(logits.reshape(-1, N_VOCAB), targets.reshape(-1))
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        if step % 100 == 0 or step == steps:
            print(f"step={step} loss={loss.item():.4f}")
        if loss.item() <= target_loss:
            return step, loss.item()
    return steps, loss.item()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, help="Optional ASCII corpus file.")
    parser.add_argument("--output-dir", type=Path, default=Path("model_hex"))
    parser.add_argument("--steps", type=int, default=3000)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--learning-rate", type=float, default=3e-3)
    parser.add_argument("--target-loss", type=float, default=0.35)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--allow-unconverged", action="store_true")
    args = parser.parse_args()
    if args.steps <= 0 or args.batch_size <= 0 or args.learning_rate <= 0:
        raise ValueError("steps, batch-size, and learning-rate must be positive")

    torch.manual_seed(args.seed)
    random.seed(args.seed)
    symbols = vocabulary()
    corpus = args.corpus.read_text(encoding="ascii") if args.corpus else DEFAULT_CORPUS
    tokens = encode_corpus(corpus, symbols)
    generator = torch.Generator().manual_seed(args.seed)
    model = MicroTransformer()
    steps_completed, final_loss = train(
        model,
        tokens,
        args.steps,
        args.batch_size,
        args.learning_rate,
        args.target_loss,
        generator,
    )
    if final_loss > args.target_loss and not args.allow_unconverged:
        raise RuntimeError(
            f"training did not reach target loss {args.target_loss:.4f}; final loss was {final_loss:.4f}"
        )

    parameters = {
        name: nearest_power_of_two_symmetric_int8(parameter)
        for name, parameter in parameter_exports(model).items()
    }
    activation_shifts = calibrated_activation_shifts(model, tokens[:L_SEQ])
    weights_dir = args.output_dir
    weights_dir.mkdir(parents=True, exist_ok=True)
    for name, quantized in parameters.items():
        write_readmemh(weights_dir / f"{name}.hex", quantized.values)
    write_quantization_header(args.output_dir / "quantization_config.h", parameters, activation_shifts)
    manifest = {
        "architecture": {
            "vocab_size": N_VOCAB,
            "d_model": D_MODEL,
            "context_length": L_SEQ,
            "d_ff": D_FF,
            "attention_heads": 1,
            "attention_dk": D_MODEL,
            "attention_dk_shift": 2,
        },
        "vocabulary": symbols,
        "format": {
            "element_type": "signed_int8",
            "encoding": "two_complement_hex",
            "storage_order": "row_major_output_input",
            "scale": "dequantized_value = int8_value * 2^scale_shift",
        },
        "training": {
            "steps_completed": steps_completed,
            "final_loss": final_loss,
            "target_loss": args.target_loss,
            "corpus_characters": len(tokens),
        },
        "activation_scale_shifts": activation_shifts,
        "tensors": {
            name: {
                "file": f"{name}.hex",
                "shape": list(quantized.values.shape),
                "scale_shift": quantized.scale_shift,
            }
            for name, quantized in parameters.items()
        },
    }
    (args.output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="ascii",
    )
    print(f"Exported {len(parameters)} INT8 tensors to {weights_dir}")
    print(f"Final loss: {final_loss:.4f} after {steps_completed} steps")


if __name__ == "__main__":
    main()
