# RV32I FPGA NPU

Starter project for a memory-mapped FPGA NPU attached to the RV32I CPU in
[`rv32i-starflight-fpga`](https://github.com/SourCream206/rv32i-starflight-fpga).
The first projection engine tiles a signed INT8 4x4 MAC array into an
autonomous 16x16 matrix-vector unit for a tiny character-level Transformer.

## Scope

This project deliberately does not yet implement full attention or layer
normalization. Its projection controller accumulates sixteen 4x4 MAC tiles:

```text
output[row] = bias[row] + sum(weight[row][column] * input[column])
```

All multiplication inputs are signed two's-complement INT8. Intermediate sums
are signed INT32; final activation memory is signed Q4.4. The optional softmax
unit uses a 64-entry exponential LUT and emits unsigned Q0.16 probabilities.

## Layout

```text
python/export_int8_linear.py  PTQ example and $readmemh hex export
python/reference_model.py     Bit-exact MAC reference model
scripts/train_and_export.py   Train and export the 64-token micro-Transformer
rtl/mac_array_4x4.sv          4x4 signed MAC array
tb/tb_mac_array_4x4.sv        Self-checking SystemVerilog testbench
rtl/npu_peripheral.sv         Autonomous 16x16 tiled projection controller
tb/tb_npu_peripheral.sv       Self-checking tiled projection/softmax testbench
docs/memory_map.md            16x16 NPU register map and fixed-point contract
docs/rv32i_integration.md     Exact existing-CPU integration changes
```

## Quantize and export

Install the Python dependencies, then run:

```powershell
python -m pip install -r requirements.txt
python python/export_int8_linear.py --output-dir build/weights
```

The script runs PyTorch static post-training quantization with representative
calibration inputs. `weights.hex` contains one signed INT8 weight per line for
`$readmemh`; `bias.hex` contains the corresponding quantized INT32 bias. INT32
bias is required for a correct INT8 x INT8 -> INT32 MAC datapath.

## Train and export the micro-Transformer

The training/export script defines a one-layer, single-head causal Transformer
with a 64-character ASCII vocabulary, `d_model=16`, `L_seq=16`, and `d_ff=32`.
It trains on a short built-in corpus, then uses power-of-two symmetric INT8 PTQ
so every scale is representable in RTL as a shift:

```powershell
python scripts/train_and_export.py --output-dir build/transformer
```

Exports include every embedding, layer-normalization affine parameter, linear
weight, and bias. `weights/W_Q.hex`, `weights/W_K.hex`, `weights/W_V.hex`,
`weights/W_O.hex`, `weights/W_FF1.hex`, `weights/W_FF2.hex`, and
`weights/W_VOCAB.hex` are row-major `[output][input]` matrices, directly
compatible with a 4x4 MAC tile. `manifest.json` specifies every tensor shape
and shift; `quantization_config.h` provides the firmware constants. The script
only exports after reaching its loss target unless `--allow-unconverged` is set.
`NPU_ATTENTION_DK_SHIFT` is the exact `1/sqrt(16)` divide-by-four shift;
`NPU_FFN_SCALING_SHIFT` and `NPU_SOFTMAX_INPUT_SHIFT` are calibrated
power-of-two activation scales.

## Simulate

With Icarus Verilog:

```powershell
iverilog -g2012 -s tb_mac_array_4x4 -o build/mac_tb rtl/mac_array_4x4.sv tb/tb_mac_array_4x4.sv
vvp build/mac_tb
iverilog -g2012 -s tb_npu_peripheral -o build/npu_tb rtl/mac_array_4x4.sv rtl/npu_peripheral.sv tb/tb_npu_peripheral.sv
vvp build/npu_tb
```

The testbench must print `PASS`.

## Memory map

The NPU implements the `0x0006_xxxx` range used by the existing CPU. See
[docs/memory_map.md](docs/memory_map.md) for the complete map and software
protocol, then use [docs/rv32i_integration.md](docs/rv32i_integration.md) to
attach it to the RV32I system.
