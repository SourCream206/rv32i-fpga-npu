module riscv_soc #(
    parameter IMEM_FILE = ""
) (
    input  wire       clk,
    input  wire       rst,
    output reg [9:0]  leds
);

    wire [31:0] imem_addr;
    wire [31:0] imem_rdata;
    wire [31:0] cpu_addr;
    wire [31:0] cpu_wdata;
    wire [3:0]  cpu_wstrb;
    reg  [31:0] cpu_rdata;
    wire        cpu_we = |cpu_wstrb;
    wire        dmem_select = (cpu_addr >= 32'h0000_4000) && (cpu_addr < 32'h0000_6000);
    wire        led_select = cpu_addr == 32'h0004_0000;
    wire        npu_reg_select = (cpu_addr >= 32'h0006_0000) && (cpu_addr <= 32'h0006_0030);
    wire        npu_input_select = (cpu_addr >= 32'h0006_1000) && (cpu_addr < 32'h0006_1010);
    wire        npu_output_select = (cpu_addr >= 32'h0006_2000) && (cpu_addr < 32'h0006_2010);
    wire [31:0] dmem_rdata;
    wire [31:0] npu_rdata;
    wire signed [7:0] npu_output_byte;
    wire [7:0] npu_input_byte;

    function [7:0] selected_byte;
        input [31:0] data;
        input [3:0] strobe;
        begin
            case (strobe)
                4'b0001: selected_byte = data[7:0];
                4'b0010: selected_byte = data[15:8];
                4'b0100: selected_byte = data[23:16];
                default: selected_byte = data[31:24];
            endcase
        end
    endfunction

    assign npu_input_byte = selected_byte(cpu_wdata, cpu_wstrb);

    riscv_core core (
        .clk(clk),
        .rst(rst),
        .imem_addr(imem_addr),
        .imem_rdata(imem_rdata),
        .dmem_addr(cpu_addr),
        .dmem_wdata(cpu_wdata),
        .dmem_wstrb(cpu_wstrb),
        .dmem_rdata(cpu_rdata)
    );

    imem #(.INIT_FILE(IMEM_FILE)) instruction_memory (
        .addr(imem_addr),
        .rdata(imem_rdata)
    );

    dmem data_memory (
        .clk(clk),
        .we(cpu_we && dmem_select),
        .byte_enable(cpu_wstrb),
        .addr(cpu_addr),
        .wdata(cpu_wdata),
        .rdata(dmem_rdata)
    );

    npu_peripheral npu (
        .clk(clk),
        .rst(rst),
        .bus_we(cpu_we && npu_reg_select),
        .bus_byte_enable(cpu_wstrb),
        .bus_addr(cpu_addr),
        .bus_wdata(cpu_wdata),
        .bus_rdata(npu_rdata),
        .input_bank_we(cpu_we && npu_input_select),
        .input_bank_addr(cpu_addr[3:0]),
        .input_bank_wdata(npu_input_byte),
        .output_bank_addr(cpu_addr[3:0]),
        .output_bank_rdata(npu_output_byte)
    );

    always @(posedge clk) begin
        if (rst)
            leds <= 10'd0;
        else if (cpu_we && led_select)
            leds <= cpu_wdata[9:0];
    end

    always @* begin
        if (dmem_select)
            cpu_rdata = dmem_rdata;
        else if (npu_reg_select)
            cpu_rdata = npu_rdata;
        else if (npu_output_select)
            cpu_rdata = {4{npu_output_byte}};
        else if (led_select)
            cpu_rdata = {22'd0, leds};
        else
            cpu_rdata = 32'd0;
    end
endmodule
