module de10_lite_top (
    input  wire       MAX10_CLK1_50,
    input  wire [1:0] KEY,
    output wire [9:0] LEDR
);

    riscv_soc #(
        .IMEM_FILE("../software/imem.hex")
    ) soc (
        .clk(MAX10_CLK1_50),
        .rst(~KEY[0]),
        .leds(LEDR)
    );
endmodule
