module tb_npu_peripheral;

    logic clk = 1'b0;
    logic rst;
    logic bus_we;
    logic [3:0] bus_byte_enable;
    logic [31:0] bus_addr;
    logic [31:0] bus_wdata;
    logic [31:0] bus_rdata;
    integer index;
    integer lane;
    logic [31:0] packed_weights;

    npu_peripheral dut (
        .clk(clk),
        .rst(rst),
        .bus_we(bus_we),
        .bus_byte_enable(bus_byte_enable),
        .bus_addr(bus_addr),
        .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata)
    );

    always #5 clk = ~clk;

    task write_register(input logic [31:0] address, input logic [31:0] data);
        begin
            bus_addr = address;
            bus_wdata = data;
            bus_byte_enable = 4'hF;
            bus_we = 1'b1;
            @(posedge clk);
            #1;
            bus_we = 1'b0;
        end
    endtask

    task expect_read(input logic [31:0] address, input logic [31:0] expected);
        begin
            bus_addr = address;
            #1;
            if (bus_rdata !== expected)
                $fatal(1, "Read %h: expected %h, got %h", address, expected, bus_rdata);
        end
    endtask

    initial begin
        rst = 1'b1;
        bus_we = 1'b0;
        bus_byte_enable = '0;
        bus_addr = '0;
        bus_wdata = '0;

        repeat (2) @(posedge clk);
        rst = 1'b0;

        write_register(32'h0006_0008, 32'd0);
        write_register(32'h0006_000C, 32'h0101_0101);
        write_register(32'h0006_000C, 32'h0101_0101);
        write_register(32'h0006_000C, 32'h0101_0101);
        write_register(32'h0006_000C, 32'h0101_0101);

        write_register(32'h0006_0010, 32'd0);
        for (index = 0; index < 64; index = index + 1) begin
            packed_weights = '0;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (((index * 4 + lane) % 17) == 0)
                    packed_weights[lane * 8 +: 8] = 8'd1;
            write_register(32'h0006_0014, packed_weights);
        end

        write_register(32'h0006_0018, 32'd0);
        write_register(32'h0006_001C, 32'd0);
        write_register(32'h0006_001C, 32'd0);
        write_register(32'h0006_001C, 32'd0);
        write_register(32'h0006_001C, 32'd0);
        write_register(32'h0006_0020, 32'd0);
        write_register(32'h0006_0000, 32'h0000_0009);
        expect_read(32'h0006_0004, 32'h0000_0001);

        repeat (100) @(posedge clk);
        expect_read(32'h0006_0004, 32'h0000_0002);
        write_register(32'h0006_0024, 32'd0);
        expect_read(32'h0006_0028, 32'h0101_0101);
        expect_read(32'h0006_002C, 32'd4095);

        write_register(32'h0006_0030, -32'sd1);
        write_register(32'h0006_0000, 32'h0000_0001);
        repeat (60) @(posedge clk);
        expect_read(32'h0006_0024, 32'd0);
        expect_read(32'h0006_0028, 32'h0202_0202);
        $display("PASS: 16x16 tiled NPU projection and softmax");
        $finish;
    end

endmodule
