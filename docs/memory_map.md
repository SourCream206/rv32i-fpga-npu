# 16x16 projection NPU memory map

The NPU reserves `0x0006_0000` through `0x0006_002F` in the RV32I data-memory
map. One start command executes all sixteen 4x4 tiles required for a 16x16
matrix-vector projection. No CPU intervention occurs while the NPU is busy.

| Address | Name | Access | Description |
|---|---|---|---|
| `0x0006_0000` | `NPU_CONTROL` | WO | Bit 0: start. Bit 1: cancel. Bit 2: apply clipped-ReLU GeLU approximation. Bit 3: calculate softmax. |
| `0x0006_0004` | `NPU_STATUS` | RO | Bit 0: busy. Bit 1: done. |
| `0x0006_0008` | `NPU_INPUT_ADDR` | RW | First signed INT8 input index, `0..15`. |
| `0x0006_000C` | `NPU_INPUT_DATA` | WO | Four packed signed INT8 inputs, little-endian. Address autoincrements by four. |
| `0x0006_0010` | `NPU_WEIGHT_ADDR` | RW | First signed INT8 weight index, `0..255`. |
| `0x0006_0014` | `NPU_WEIGHT_DATA` | WO | Four packed weights. Row-major weight index is `row * 16 + column`. Address autoincrements by four. |
| `0x0006_0018` | `NPU_BIAS_ADDR` | RW | First signed INT8 bias index, `0..15`. |
| `0x0006_001C` | `NPU_BIAS_DATA` | WO | Four packed signed INT8 biases. Address autoincrements by four. |
| `0x0006_0020` | `NPU_SCALE` | RW | Bits 3:0: projection arithmetic right shift. Bits 11:8: softmax-delta right shift. |
| `0x0006_0024` | `NPU_OUTPUT_ADDR` | RW | First output or softmax index, `0..15`. |
| `0x0006_0028` | `NPU_OUTPUT_DATA` | RO | Four packed signed Q4.4 activations, little-endian, starting at output address. |
| `0x0006_002C` | `NPU_SOFTMAX_DATA` | RO | Q0.16 probability for output address in bits 15:0. Valid after a start with control bit 3 set. |

## Datapath

`W_MEM`, `IN_MEM`, and `ACT_MEM` are declared with the Quartus `M9K` RAM-style
attribute. The controller iterates output tile `0..3` and input tile `0..3`.
For each tile, it clears the 4x4 MAC array, executes one signed INT8
matrix-vector product, and accumulates the four INT32 results into the active
four output rows. Loaded signed INT8 biases initialize those accumulators.

After each output row's fourth input tile, the controller applies the
programmed arithmetic right shift and saturates to signed Q4.4. When control
bit 2 is set, negative results clip to zero; this is the selected hardware
GeLU approximation.

With control bit 3 set, a 64-entry LUT evaluates `exp(-delta / 16)` for
clamped `delta` indices `0..63`, where `delta` is the shifted difference from
the largest Q4.4 logit. The NPU sums all LUT values and normalizes them to
Q0.16. For equal logits, each of sixteen outputs is `4095`.

## Software sequence

1. While `NPU_STATUS.busy` is clear, write 16 inputs, 256 weights, and 16
   biases through their address/data port pairs.
2. Write shifts to `NPU_SCALE`.
3. Write `1`, `5`, `9`, or `13` to `NPU_CONTROL` for raw, clipped-ReLU,
   softmax, or clipped-ReLU-plus-softmax execution.
4. Poll `NPU_STATUS.done`.
5. Set `NPU_OUTPUT_ADDR`, then read packed activations from `NPU_OUTPUT_DATA`.
   If enabled, read one Q0.16 probability from `NPU_SOFTMAX_DATA`.
