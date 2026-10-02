# RV32I FPGA NPU

Starter project for a memory-mapped FPGA NPU attached to the RV32I CPU in
[`rv32i-starflight-fpga`](https://github.com/SourCream206/rv32i-starflight-fpga).
The first verified block is a signed INT8 4x4 matrix-vector MAC array. It is a
building block for the linear projections in a tiny character-level Transformer.

## Scope

This project deliberately does not yet implement attention, layer normalization,
or hardware softmax. The MAC array accumulates a 4x4 signed matrix-vector
product across enabled cycles:

```text
accumulator[row] += sum(weight[row][column] * activation[column])
```

All multiplication inputs are signed two's-complement INT8. Accumulators wrap
in signed INT32 two's-complement arithmetic, matching the Python reference.

## Layout

```text
python/export_int8_linear.py  PTQ example and $readmemh hex export
python/reference_model.py     Bit-exact MAC reference model
rtl/mac_array_4x4.sv          4x4 signed MAC array
tb/tb_mac_array_4x4.sv        Self-checking SystemVerilog testbench
docs/memory_map.md            Proposed RV32I NPU register map
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

## Simulate

With Icarus Verilog:

```powershell
iverilog -g2012 -s tb_mac_array_4x4 -o build/mac_tb rtl/mac_array_4x4.sv tb/tb_mac_array_4x4.sv
vvp build/mac_tb
```

The testbench must print `PASS`.

## Memory map

The existing CPU uses upper 16-bit address decoding. Reserve `0x0006_xxxx` for
the NPU. See [docs/memory_map.md](docs/memory_map.md) for the complete map and
software protocol.
