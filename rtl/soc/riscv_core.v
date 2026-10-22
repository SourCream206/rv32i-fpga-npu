module riscv_core (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    output wire [31:0] dmem_addr,
    output reg  [31:0] dmem_wdata,
    output reg  [3:0]  dmem_wstrb,
    input  wire [31:0] dmem_rdata
);

    reg [31:0] pc;
    reg [31:0] registers [0:31];
    // MAX 10 block RAM reads are clocked: one fetch phase and one load writeback phase.
    localparam [1:0] FETCH = 2'd0, EXECUTE = 2'd1, LOAD_WRITEBACK = 2'd2;
    reg [1:0] phase;
    reg [31:0] pending_addr;
    reg [4:0] pending_rd;
    reg [2:0] pending_funct3;
    wire [6:0] opcode = imem_rdata[6:0];
    wire [2:0] funct3 = imem_rdata[14:12];
    wire [6:0] funct7 = imem_rdata[31:25];
    wire [4:0] rd = imem_rdata[11:7];
    wire [4:0] rs1 = imem_rdata[19:15];
    wire [4:0] rs2 = imem_rdata[24:20];
    wire [31:0] rs1_value = rs1 == 0 ? 32'd0 : registers[rs1];
    wire [31:0] rs2_value = rs2 == 0 ? 32'd0 : registers[rs2];
    wire [31:0] imm_i = {{20{imem_rdata[31]}}, imem_rdata[31:20]};
    wire [31:0] imm_s = {{20{imem_rdata[31]}}, imem_rdata[31:25], imem_rdata[11:7]};
    wire [31:0] imm_b = {{19{imem_rdata[31]}}, imem_rdata[31], imem_rdata[7],
                         imem_rdata[30:25], imem_rdata[11:8], 1'b0};
    wire [31:0] imm_u = {imem_rdata[31:12], 12'd0};
    wire [31:0] imm_j = {{11{imem_rdata[31]}}, imem_rdata[31], imem_rdata[19:12],
                         imem_rdata[20], imem_rdata[30:21], 1'b0};

    reg [31:0] next_pc;
    reg        write_rd;
    reg [31:0] rd_value;
    integer index;

    assign imem_addr = pc;
    assign dmem_addr = phase == LOAD_WRITEBACK ? pending_addr :
                       phase == EXECUTE && opcode == 7'b0000011 ? rs1_value + imm_i :
                       phase == EXECUTE && opcode == 7'b0100011 ? rs1_value + imm_s : 32'd0;

    function [31:0] loaded_value;
        input [31:0] word;
        input [31:0] address;
        input [2:0] size;
        reg [7:0] byte_value;
        reg [15:0] half_value;
        begin
            byte_value = word >> (8 * address[1:0]);
            half_value = word >> (16 * address[1]);
            case (size)
                3'b000: loaded_value = {{24{byte_value[7]}}, byte_value};
                3'b001: loaded_value = {{16{half_value[15]}}, half_value};
                3'b010: loaded_value = word;
                3'b100: loaded_value = {24'd0, byte_value};
                3'b101: loaded_value = {16'd0, half_value};
                default: loaded_value = 32'd0;
            endcase
        end
    endfunction

    always @* begin
        next_pc = pc + 4;
        write_rd = 1'b0;
        rd_value = 32'd0;
        dmem_wdata = 32'd0;
        dmem_wstrb = 4'd0;

        case (opcode)
            7'b0110111: begin write_rd = 1'b1; rd_value = imm_u; end
            7'b0010111: begin write_rd = 1'b1; rd_value = pc + imm_u; end
            7'b1101111: begin
                write_rd = 1'b1;
                rd_value = pc + 4;
                next_pc = pc + imm_j;
            end
            7'b1100111: begin
                write_rd = 1'b1;
                rd_value = pc + 4;
                next_pc = (rs1_value + imm_i) & ~32'd1;
            end
            7'b1100011: begin
                case (funct3)
                    3'b000: if (rs1_value == rs2_value) next_pc = pc + imm_b;
                    3'b001: if (rs1_value != rs2_value) next_pc = pc + imm_b;
                    3'b100: if ($signed(rs1_value) < $signed(rs2_value)) next_pc = pc + imm_b;
                    3'b101: if ($signed(rs1_value) >= $signed(rs2_value)) next_pc = pc + imm_b;
                    3'b110: if (rs1_value < rs2_value) next_pc = pc + imm_b;
                    3'b111: if (rs1_value >= rs2_value) next_pc = pc + imm_b;
                endcase
            end
            7'b0000011: begin end // The read completes in LOAD_WRITEBACK.
            7'b0100011: begin
                case (funct3)
                    3'b000: begin
                        dmem_wstrb = 4'b0001 << dmem_addr[1:0];
                        dmem_wdata = rs2_value << (8 * dmem_addr[1:0]);
                    end
                    3'b001: begin
                        dmem_wstrb = dmem_addr[1] ? 4'b1100 : 4'b0011;
                        dmem_wdata = rs2_value << (16 * dmem_addr[1]);
                    end
                    3'b010: begin
                        dmem_wstrb = 4'b1111;
                        dmem_wdata = rs2_value;
                    end
                endcase
            end
            7'b0010011: begin
                write_rd = 1'b1;
                case (funct3)
                    3'b000: rd_value = rs1_value + imm_i;
                    3'b010: rd_value = $signed(rs1_value) < $signed(imm_i);
                    3'b011: rd_value = rs1_value < imm_i;
                    3'b100: rd_value = rs1_value ^ imm_i;
                    3'b110: rd_value = rs1_value | imm_i;
                    3'b111: rd_value = rs1_value & imm_i;
                    3'b001: rd_value = rs1_value << imem_rdata[24:20];
                    3'b101: begin
                        if (imem_rdata[30])
                            rd_value = $signed(rs1_value) >>> imem_rdata[24:20];
                        else
                            rd_value = rs1_value >> imem_rdata[24:20];
                    end
                endcase
            end
            7'b0110011: begin
                write_rd = 1'b1;
                case (funct3)
                    3'b000: rd_value = funct7[5] ? rs1_value - rs2_value : rs1_value + rs2_value;
                    3'b001: rd_value = rs1_value << rs2_value[4:0];
                    3'b010: rd_value = $signed(rs1_value) < $signed(rs2_value);
                    3'b011: rd_value = rs1_value < rs2_value;
                    3'b100: rd_value = rs1_value ^ rs2_value;
                    3'b101: begin
                        if (funct7[5])
                            rd_value = $signed(rs1_value) >>> rs2_value[4:0];
                        else
                            rd_value = rs1_value >> rs2_value[4:0];
                    end
                    3'b110: rd_value = rs1_value | rs2_value;
                    3'b111: rd_value = rs1_value & rs2_value;
                endcase
            end
        endcase
        if (phase != EXECUTE)
            dmem_wstrb = 4'd0;
    end

    always @(posedge clk) begin
        if (rst) begin
            pc <= 32'd0;
            phase <= FETCH;
            pending_addr <= 32'd0;
            pending_rd <= 5'd0;
            pending_funct3 <= 3'd0;
            for (index = 0; index < 32; index = index + 1)
                registers[index] <= 32'd0;
        end else begin
            case (phase)
                FETCH: phase <= EXECUTE;
                EXECUTE: begin
                    pc <= next_pc;
                    if (opcode == 7'b0000011) begin
                        pending_addr <= dmem_addr;
                        pending_rd <= rd;
                        pending_funct3 <= funct3;
                        phase <= LOAD_WRITEBACK;
                    end else begin
                        if (write_rd && rd != 0)
                            registers[rd] <= rd_value;
                        phase <= FETCH;
                    end
                end
                LOAD_WRITEBACK: begin
                    if (pending_rd != 0)
                        registers[pending_rd] <= loaded_value(dmem_rdata, pending_addr, pending_funct3);
                    phase <= FETCH;
                end
                default: phase <= FETCH;
            endcase
            registers[0] <= 32'd0;
        end
    end
endmodule
