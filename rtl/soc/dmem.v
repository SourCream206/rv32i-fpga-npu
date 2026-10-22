module dmem (
    input  wire        clk,
    input  wire        we,
    input  wire [3:0]  byte_enable,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata
);

    wire [10:0] word_addr = addr[12:2];
    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : byte_bank
            (* ramstyle = "M9K" *) reg [7:0] memory [0:2047];
            reg [7:0] read_byte;
            always @(posedge clk) begin
                if (we && byte_enable[lane])
                    memory[word_addr] <= wdata[lane * 8 +: 8];
                read_byte <= memory[word_addr];
            end
            assign rdata[lane * 8 +: 8] = read_byte;
        end
    endgenerate
endmodule
