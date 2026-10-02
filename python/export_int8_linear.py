"""Calibrate, statically quantize, and export a PyTorch Linear layer."""

from __future__ import annotations

import argparse
from pathlib import Path

import torch
from torch import nn
from torch.ao.quantization import convert, default_qconfig, prepare


class QuantizableLinear(nn.Module):
    def __init__(self, in_features: int, out_features: int) -> None:
        super().__init__()
        self.quant = torch.ao.quantization.QuantStub()
        self.linear = nn.Linear(in_features, out_features)
        self.dequant = torch.ao.quantization.DeQuantStub()

    def forward(self, inputs: torch.Tensor) -> torch.Tensor:
        return self.dequant(self.linear(self.quant(inputs)))


def write_readmemh_int8(path: Path, values: torch.Tensor) -> None:
    """Write one signed INT8 value per line as a two-digit hexadecimal byte."""

    path.write_text(
        "".join(f"{int(value) & 0xFF:02x}\n" for value in values.flatten()),
        encoding="ascii",
    )


def write_readmemh_int32(path: Path, values: torch.Tensor) -> None:
    """Write one signed INT32 value per line as eight hexadecimal digits."""

    path.write_text(
        "".join(f"{int(value) & 0xFFFF_FFFF:08x}\n" for value in values.flatten()),
        encoding="ascii",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--in-features", type=int, default=4)
    parser.add_argument("--out-features", type=int, default=4)
    parser.add_argument("--calibration-samples", type=int, default=128)
    parser.add_argument("--output-dir", type=Path, default=Path("build/weights"))
    args = parser.parse_args()

    torch.manual_seed(7)
    model = QuantizableLinear(args.in_features, args.out_features).eval()
    # A single scale is required by the first hardware revision. The FBGEMM
    # default uses per-channel weights, which would require four scales here.
    model.qconfig = default_qconfig
    prepared_model = prepare(model, inplace=False)

    calibration_data = torch.randn(args.calibration_samples, args.in_features)
    with torch.inference_mode():
        prepared_model(calibration_data)
    quantized_model = convert(prepared_model, inplace=False)

    quantized_linear = quantized_model.linear
    quantized_weight = quantized_linear.weight()
    if quantized_weight.qscheme() not in (
        torch.per_tensor_affine,
        torch.per_tensor_symmetric,
    ):
        raise RuntimeError(
            "This exporter requires per-tensor weight quantization; "
            "choose a per-tensor qconfig for this hardware target."
        )

    input_scale = float(quantized_model.quant.scale)
    weight_scale = float(quantized_weight.q_scale())
    bias_int32 = torch.round(
        quantized_linear.bias().detach() / (input_scale * weight_scale)
    ).to(torch.int32)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_readmemh_int8(args.output_dir / "weights.hex", quantized_weight.int_repr())
    write_readmemh_int32(args.output_dir / "bias.hex", bias_int32)
    (args.output_dir / "quantization.txt").write_text(
        f"input_scale={input_scale:.12g}\n"
        f"weight_scale={weight_scale:.12g}\n"
        f"weight_zero_point={quantized_weight.q_zero_point()}\n",
        encoding="ascii",
    )
    print(f"Exported {args.output_dir / 'weights.hex'}")
    print(f"Exported {args.output_dir / 'bias.hex'}")


if __name__ == "__main__":
    main()
