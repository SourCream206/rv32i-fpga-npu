module de10_lite_top (
    input  wire       MAX10_CLK1_50,
    input  wire       KEY0,
    output wire [9:0] LEDR
);

    reg [1:0] reset_pipe = 2'b11;
    reg core_clk = 1'b0;
    always @(posedge MAX10_CLK1_50) core_clk <= ~core_clk;

    always @(posedge MAX10_CLK1_50 or negedge KEY0) begin
        if (!KEY0) reset_pipe <= 2'b11;
        else reset_pipe <= {reset_pipe[0], 1'b0};
    end

    riscv_soc #(
        .IMEM_FILE("../software/imem.hex")
    ) soc (
        .clk(core_clk),
        .rst(reset_pipe[1]),
        .leds(LEDR)
    );
endmodule
