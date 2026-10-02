module tb_mac_array_4x4;

    logic clk = 1'b0;
    logic rst;
    logic clear;
    logic enable;
    logic signed [7:0] activations [0:3];
    logic signed [7:0] weights [0:3][0:3];
    logic signed [31:0] accumulators [0:3];

    mac_array_4x4 dut (
        .clk(clk),
        .rst(rst),
        .clear(clear),
        .enable(enable),
        .activations(activations),
        .weights(weights),
        .accumulators(accumulators)
    );

    always #5 clk = ~clk;

    task expect_accumulators(
        input logic signed [31:0] expected0,
        input logic signed [31:0] expected1,
        input logic signed [31:0] expected2,
        input logic signed [31:0] expected3
    );
        begin
            if ((accumulators[0] !== expected0) ||
                (accumulators[1] !== expected1) ||
                (accumulators[2] !== expected2) ||
                (accumulators[3] !== expected3)) begin
                $fatal(1, "Expected [%0d, %0d, %0d, %0d], got [%0d, %0d, %0d, %0d]",
                    expected0, expected1, expected2, expected3,
                    accumulators[0], accumulators[1], accumulators[2], accumulators[3]);
            end
        end
    endtask

    initial begin
        rst = 1'b1;
        clear = 1'b0;
        enable = 1'b0;
        activations = '{8'sd1, -8'sd2, 8'sd3, -8'sd4};
        weights[0] = '{8'sd1, 8'sd2, 8'sd3, 8'sd4};
        weights[1] = '{-8'sd1, 8'sd0, -8'sd3, 8'sd2};
        weights[2] = '{8'sd127, -8'sd128, 8'sd1, -8'sd1};
        weights[3] = '{8'sd8, -8'sd6, 8'sd5, -8'sd5};

        @(posedge clk);
        rst = 1'b0;
        enable = 1'b1;
        @(posedge clk);
        #1;
        expect_accumulators(-32'sd10, -32'sd18, 32'sd390, 32'sd55);

        @(posedge clk);
        #1;
        expect_accumulators(-32'sd20, -32'sd36, 32'sd780, 32'sd110);

        enable = 1'b0;
        clear = 1'b1;
        @(posedge clk);
        #1;
        expect_accumulators(32'sd0, 32'sd0, 32'sd0, 32'sd0);
        $display("PASS: mac_array_4x4");
        $finish;
    end

endmodule
