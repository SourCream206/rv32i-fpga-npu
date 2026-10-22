module imem #(
    parameter INIT_FILE = ""
) (
    input  wire        clk,
    input  wire [31:0] addr,
    output reg  [31:0] rdata,
    input  wire [31:0] data_addr,
    output reg  [31:0] data_rdata
);

    (* ramstyle = "M9K" *) reg [31:0] memory [0:4095];

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, memory);
    end

    always @(posedge clk) begin
        rdata <= memory[addr[13:2]];
        data_rdata <= memory[data_addr[13:2]];
    end
endmodule
