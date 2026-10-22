# INT8 NPU: bring-up and validation record

## System under test

Terasic DE10-Lite (`10M50DAF484C7G`) running a 25 MHz RV32I SoC derived
from the board's 50 MHz clock. Bare-metal firmware loads INT8 weights and
activations into a memory-mapped 4x4 MAC array, reusing it for 16x16
matrix-vector projections. The fixed 16-character prompt is
`THE SMALL FPGA L`; the committed quantized model predicts character ID 37
(`E`). The board exposes the result as a binary number on ten LEDs.

The firmware computes K and V for all 16 positions, Q for the final position,
attention scores and weighted values, output and feed-forward projections,
then vocabulary logits and argmax. The NPU also performs the 16-element
fixed-point softmax. This is a one-layer next-character demonstrator, not a
general text-generation system.

## Evidence

| Check | Result | Method and limits |
|---|---|---|
| MAC arithmetic | Pass | Self-checking Questa testbench. |
| Tiled NPU and softmax | Pass | Self-checking Questa testbench. |
| Full SoC and firmware | Pass, token ID 37 | Testbench requires the expected LED write. |
| Intermediate numerical values | Pass, 12 stages | Instrumented firmware trace matches the independent Python fixed-point reference. |
| Uninstrumented inference latency | 279,960 SoC cycles; 11.20 ms at 25 MHz | Cycle count from full SoC simulation. The time is calculated from the constrained clock; it has not been measured with an oscilloscope. |
| Quartus fit | Pass | 19,394 / 49,760 logic elements (39%); 196,864 / 1,677,312 memory bits (12%); 16 / 288 9-bit multiplier elements. |
| Timing, slow 85 C model | Pass | 31.7 MHz restricted Fmax for the 25 MHz SoC clock; +8.457 ns setup slack. Worst reported hold slack across corners: +0.100 ns. |
| FPGA power estimate | 177.18 mW total thermal power | Quartus Power Analyzer after fitting: 61.83 mW core dynamic, 90.30 mW core static, 25.05 mW I/O. **Low confidence:** vectorless activity estimation, insufficient toggle-rate data, and no board thermal model. This is an FPGA estimate, not measured board-input power. |
| Physical board output | Matches expected token | On 2026-10-21, the user reported LEDR[5], LEDR[2], and LEDR[0] lit (32 + 4 + 1 = 37). This checks the visible fixed-prompt result, not every internal value or electrical characteristic. |

Reproduce the simulation checks with `scripts/verify.ps1 -Trace` after
installing a RV32I GCC toolchain and Questa. The script restores the normal
firmware image after tracing. Build the FPGA image from `fpga/` with
`quartus_sh --flow compile npu_transformer`. See the root `README.md` for
exact setup and tool arguments. Quartus generates the fit and timing reports
alongside the `.sof` programming file.

Run `quartus_pow npu_transformer -c npu_transformer` from `fpga/` after the
fit to reproduce the vectorless power estimate. Its report is
`fpga/npu_transformer.pow.rpt`. Quartus labels this estimate low confidence;
it should not be converted into a claimed measured energy per inference.

## Next characterization without lab instruments

1. Generate representative switching activity from a full-system simulation
   and feed it into Quartus Power Analyzer. Report how many signals use
   simulation activity versus vectorless estimates; retain the tool's
   confidence label. This can improve the estimate but cannot turn it into a
   physical measurement.
2. Benchmark the same fixed prompt and additional known vectors in simulation.
   Report cycle counts, numerical agreement, and failure cases separately.
3. Export a small reproducible evidence bundle: exact build command, tool
   versions, fit/timing/power summaries, reference output, test logs, and a
   photo of the LED result if available.

## Optional future physical characterization

To extend this from functional bring-up to a board-validation study, run a
repeatable workload and record:

1. **Latency:** expose an inference-active marker on a GPIO pin and measure
   its pulse width on an oscilloscope. Compare it with the simulated 11.20 ms.
2. **Power:** measure board input voltage and current at idle and under a
   repeated inference workload. Report the measurement point, instrument,
   sample rate, uncertainty, and the difference in input power. Board input
   power is not FPGA-core power.
3. **Robustness:** repeat cold boots and pushbutton resets, logging the LED
   result and any failures. Test at least one deliberately different model or
   known vector to avoid relying on a single expected output.
4. **Automation:** capture the measurements in CSV, generate plots with
   Python, and compare against explicit pass/fail limits.

No measured power or temperature number is claimed. The current board check
covers one committed model and one fixed prompt.
