module tb_soc_npu;

    logic clk = 1'b0;
    logic rst = 1'b1;
    wire [9:0] leds;
    integer cycles;
    logic saw_led_write = 1'b0;
    logic [9:0] expected_leds;

    riscv_soc #(
        .IMEM_FILE("software/imem.hex")
    ) dut (
        .clk(clk),
        .rst(rst),
        .leds(leds)
    );

    always #10 clk = ~clk;

    always @(posedge clk) begin
        if (saw_led_write && leds !== expected_leds)
            $fatal(1, "LED_REG expected %0d, got %0d", expected_leds, leds);
        if (!rst && dut.cpu_we && dut.led_select) begin
            saw_led_write <= 1'b1;
            if (dut.cpu_wdata[31:10] != 0)
                $fatal(1, "invalid token write: %h", dut.cpu_wdata);
            expected_leds <= dut.cpu_wdata[9:0];
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < 1000000 && !saw_led_write; cycles = cycles + 1)
            @(posedge clk);
        if (!saw_led_write)
            $fatal(1, "firmware did not write LED_REG within %0d cycles", cycles);
        $display("PASS: RV32I firmware completed NPU orchestration, token=%0d", leds);
        $finish;
    end
endmodule
