# NPU memory map

The existing RV32I system decodes peripherals by `dmem_addr[31:16]`. Reserve
`0x0006_0000` through `0x0006_00FF` for the NPU.

| Address | Name | Access | Description |
|---|---|---|---|
| `0x0006_0000` | `NPU_CONTROL` | RW | Write bit 0 as `1` to start; write bit 1 as `1` to clear the engine. |
| `0x0006_0004` | `NPU_STATUS` | RO | Bit 0: busy. Bit 1: done; cleared when a new start is accepted. |
| `0x0006_0008` | `NPU_INPUT0` | RW | Four signed INT8 activations packed little-endian: lanes 0-3 in bits 7:0 through 31:24. |
| `0x0006_000C` | `NPU_INPUT1` | RW | Reserved for future token embedding or the next vector. |
| `0x0006_0010` | `NPU_WEIGHT_ADDR` | RW | Index of the first weight byte to load from the exported `weights.hex` image. |
| `0x0006_0014` | `NPU_WEIGHT_DATA` | RW | Four signed INT8 weights packed little-endian. Autoincrement `NPU_WEIGHT_ADDR` by four after each write. |
| `0x0006_0020` | `NPU_ACCUM0` | RO | Signed INT32 output lane 0. |
| `0x0006_0024` | `NPU_ACCUM1` | RO | Signed INT32 output lane 1. |
| `0x0006_0028` | `NPU_ACCUM2` | RO | Signed INT32 output lane 2. |
| `0x0006_002C` | `NPU_ACCUM3` | RO | Signed INT32 output lane 3. |
| `0x0006_0030` | `NPU_SOFTMAX0` | RO | Reserved for unsigned Q0.16 probability lane 0. |
| `0x0006_0034` | `NPU_SOFTMAX1` | RO | Reserved for unsigned Q0.16 probability lane 1. |
| `0x0006_0038` | `NPU_SOFTMAX2` | RO | Reserved for unsigned Q0.16 probability lane 2. |
| `0x0006_003C` | `NPU_SOFTMAX3` | RO | Reserved for unsigned Q0.16 probability lane 3. |

## Software protocol

1. Write the packed four-lane activation vector to `NPU_INPUT0`.
2. Load sixteen signed INT8 weights through `NPU_WEIGHT_ADDR` and
   `NPU_WEIGHT_DATA`, or initialize the NPU weight RAM with `weights.hex`.
3. Write `1` to `NPU_CONTROL` bit 1 to clear prior accumulators.
4. Write `1` to `NPU_CONTROL` bit 0 to start the matrix-vector operation.
5. Poll `NPU_STATUS.done`, then read `NPU_ACCUM0` through `NPU_ACCUM3`.

The first hardware revision leaves softmax reserved. Firmware can dequantize
the four INT32 logits and calculate softmax until a fixed-point approximation
is added. This keeps the initial FPGA integration small and fully verifiable.
