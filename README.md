# RV32I FPGA NPU character demo

A small RV32I SoC controls a signed INT8 4×4 MAC array on the Terasic DE10-Lite.
The board runs a fixed 16-character prompt, `THE SMALL FPGA L`, through a
quantized one-layer, single-head causal decoder and displays the predicted
character ID on `LEDR[9:0]`. With the committed model the expected ID is **37**,
which maps to **E** (`ASCII 0x20 + 37`). The LEDs show the numeric ID, not text.

The model has a 64-symbol vocabulary (space through underscore), 16-wide hidden
vectors, a 32-wide feed-forward layer, and no LayerNorm. The training script
uses PyTorch GELU. Firmware uses a generated Q4.4 GELU lookup table. The NPU
performs all matrix-vector projections and the 16-element attention softmax;
RV32I computes attention scores and weighted values, bias scaling, residuals,
and argmax. Only the final prompt position is evaluated after K and V have been
computed for all 16 positions. This is sufficient for one-layer causal
next-character prediction.

## Build the committed demo

Requirements: Python 3 with NumPy, a RISC-V bare-metal GCC toolchain, and
Questa or another SystemVerilog simulator. The firmware build needs only Python
standard-library modules. The toolchain prefix may be `riscv32-unknown-elf` or
`riscv-none-elf` depending on the installation. The official
[xPack RISC-V GCC install guide](https://xpack-dev-tools.github.io/riscv-none-elf-gcc-xpack/docs/install/)
provides a Windows toolchain if one is not already installed.

```powershell
python -m pip install -r requirements.txt
.\software\build.ps1 -ToolPrefix riscv-none-elf
python python\quantized_transformer.py
.\scripts\verify.ps1 -ToolPrefix riscv-none-elf -QuestaBin 'C:\path\to\questa\win64' -Trace
```

`software/build.ps1` compiles RV32I code, exports a little-endian binary, and
converts it to 32-bit `$readmemh` words in `software/imem.hex`. The linker checks
that code and constants fit the 16 KiB instruction ROM. The SoC exposes that
ROM through the data bus too, so firmware can read the exported weights.

`scripts/verify.ps1` checks the Python reference and runs MAC, NPU, and full
SoC simulations. The SoC test requires an LED write of ID 37. `-Trace` builds an
instrumented firmware image, checks 12 intermediate vectors against the Python
fixed-point reference, and restores the normal image afterward. Simulator logs
and temporary toolchain files belong in ignored `build/`.

## Train and replace the model

```powershell
python scripts\train_and_export.py --output-dir model_hex
python scripts\export_c_header.py --model-dir model_hex --output software\model_weights.h
Copy-Item model_hex\quantization_config.h software\quantization_config.h
python scripts\generate_gelu_lut.py
```

Training uses a short built-in corpus and only exports after reaching its loss
target unless `--allow-unconverged` is specified. The firmware's fixed prompt
and the test's expected token are tied to the committed export. If a model is
retrained, update the golden token from `python/quantized_transformer.py` and
recheck all traced layers. `scripts/export_c_header.py` validates the tensor
lengths against the manifest before generating the C arrays.

The firmware uses signed Q4.4 activations. It rescales the exported token and
position embeddings, then converts each exported bias into that projection's
INT32 accumulator units before shifting and saturating. FF2's 16×32 matrix is
repacked into two 16×16 column tiles and their raw sums are combined before
quantization. Vocabulary logits remain INT32 for argmax. Attention scores use
Q4.4; the NPU approximates softmax with a 64-entry `exp(-delta/16)` table and
Q0.16 probabilities. The LUT clamps score differences beyond 63, so this is a
fixed-point hardware approximation to the trained floating-point model.

## FPGA

The Quartus project is `fpga/npu_transformer.qpf`; its QSF targets
`10M50DAF484C7G`. Its SDC constrains the 50 MHz board clock and the derived
25 MHz SoC clock. Build from
the `fpga/` directory after generating `software/imem.hex`:

```powershell
quartus_sh --flow compile npu_transformer
```

Program the resulting `.sof` to the DE10-Lite, press `KEY[0]` to reset and
rerun, and read the LED bits as an unsigned number. A successful committed
model run displays 37 (`LEDR[5]`, `LEDR[2]`, and `LEDR[0]` on). The reset button
has asynchronous assertion and synchronized release.

## Files

| Path | Purpose |
|---|---|
| `scripts/train_and_export.py` | Tiny PyTorch decoder and power-of-two INT8 export |
| `model_hex/` | Committed model tensors and scale manifest |
| `python/quantized_transformer.py` | Independent fixed-point inference reference |
| `rtl/mac_array_4x4.sv`, `rtl/npu_peripheral.sv` | Projection and softmax hardware |
| `rtl/soc/` | RV32I core, ROM, RAM, and memory map |
| `software/` | Firmware, model arrays, linker, and image build |
| `tb/` | MAC, peripheral, and golden-token SoC testbenches |
| `fpga/` | DE10-Lite top, pins, and clock constraints |

See [docs/memory_map.md](docs/memory_map.md) for the register protocol.
