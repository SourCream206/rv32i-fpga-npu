module tb_soc_npu;

    logic clk = 1'b0;
    logic rst = 1'b1;
    wire [9:0] leds;
    integer cycles;
    logic saw_led_write = 1'b0;
    localparam logic [9:0] EXPECTED_TOKEN = 10'd37; // Python fixed-point reference: 'E'.

    riscv_soc #(
        .IMEM_FILE("software/imem.hex")
    ) dut (
        .clk(clk),
        .rst(rst),
        .leds(leds)
    );

    always #10 clk = ~clk;

    always @(posedge clk) begin
        if (!rst && dut.cpu_we && dut.led_select) begin
            if (dut.cpu_wdata[31]) begin
                $display("TRACE %0d %0d %0d", dut.cpu_wdata[30:24],
                         dut.cpu_wdata[23:16], $signed(dut.cpu_wdata[15:0]));
            end else begin
                saw_led_write <= 1'b1;
                if (dut.cpu_wdata !== {22'd0, EXPECTED_TOKEN})
                    $fatal(1, "expected token %0d, firmware wrote %h", EXPECTED_TOKEN, dut.cpu_wdata);
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        for (cycles = 0; cycles < 1000000 && !saw_led_write; cycles = cycles + 1)
            @(posedge clk);
        if (!saw_led_write)
            $fatal(1, "firmware did not write LED_REG within %0d cycles", cycles);
        #1;
        if (leds !== EXPECTED_TOKEN)
            $fatal(1, "LED register expected %0d, got %0d", EXPECTED_TOKEN, leds);
        $display("PASS: RV32I firmware completed NPU orchestration, token=%0d", leds);
        $finish;
    end
endmodule
