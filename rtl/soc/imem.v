module imem #(
    parameter INIT_FILE = ""
) (
    input  wire [31:0] addr,
    output wire [31:0] rdata
);

    reg [31:0] memory [0:4095];

    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, memory);
    end

    assign rdata = memory[addr[13:2]];
endmodule
