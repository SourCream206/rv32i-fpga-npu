# RV32I integration

Add `rtl/npu_peripheral.sv` and `rtl/mac_array_4x4.sv` to the Quartus project
that builds `rv32i-starflight-fpga`. The NPU uses the existing 32-bit data-memory
signals and reserves the unused `0x0006_xxxx` range.

In `rtl/riscv_soc.v`, declare the NPU read data alongside the other data-bus
wires:

```systemverilog
wire [31:0] npu_rdata;
```

Add the peripheral instance after the address-decoder declarations:

```systemverilog
npu_peripheral npu (
    .clk(clk),
    .rst(cpu_rst),
    .bus_we(cpu_we),
    .bus_byte_enable(dmem_byte_en),
    .bus_addr(dmem_addr),
    .bus_wdata(dmem_wdata),
    .bus_rdata(npu_rdata)
);
```

Add the NPU read route before the default value in the existing `cpu_rdata`
multiplexer:

```systemverilog
(dmem_addr[31:16] == 16'h0006) ? npu_rdata :
```

For example, the last part of the mux becomes:

```systemverilog
assign cpu_rdata = (dmem_addr[31:16] == 16'h0001) ? real_dmem_rdata :
                   (dmem_addr[31:16] == 16'h0002) ? {{16{tilt_x[15]}}, tilt_x} :
                   (dmem_addr[31:16] == 16'h0006) ? npu_rdata :
                   (dmem_addr == 32'h0000_0004)   ? {23'b0, ~BTN1, SW[8:1]} :
                                                      32'd0;
```

No additional write decoder is needed: `npu_peripheral` examines the same
write-enable, byte-enable, address, and write-data signals already driven by
the RV32I load-store unit.
