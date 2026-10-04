module dmem (
    input  wire        clk,
    input  wire        we,
    input  wire [3:0]  byte_enable,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata
);

    reg [31:0] memory [0:2047];
    wire [10:0] word_addr = addr[12:2];

    always @(posedge clk) begin
        if (we) begin
            if (byte_enable[0]) memory[word_addr][7:0] <= wdata[7:0];
            if (byte_enable[1]) memory[word_addr][15:8] <= wdata[15:8];
            if (byte_enable[2]) memory[word_addr][23:16] <= wdata[23:16];
            if (byte_enable[3]) memory[word_addr][31:24] <= wdata[31:24];
        end
    end

    assign rdata = memory[word_addr];
endmodule
