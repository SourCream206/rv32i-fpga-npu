module riscv_core (
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    output reg  [31:0] dmem_addr,
    output reg  [31:0] dmem_wdata,
    output reg  [3:0]  dmem_wstrb,
    input  wire [31:0] dmem_rdata
);

    reg [31:0] pc;
    reg [31:0] registers [0:31];
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
    reg [31:0] load_word;
    integer index;

    assign imem_addr = pc;

    always @* begin
        next_pc = pc + 4;
        write_rd = 1'b0;
        rd_value = 32'd0;
        dmem_addr = 32'd0;
        dmem_wdata = 32'd0;
        dmem_wstrb = 4'd0;
        load_word = dmem_rdata;

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
            7'b0000011: begin
                dmem_addr = rs1_value + imm_i;
                write_rd = 1'b1;
                case (funct3)
                    3'b000: case (dmem_addr[1:0])
                        2'd0: rd_value = {{24{load_word[7]}}, load_word[7:0]};
                        2'd1: rd_value = {{24{load_word[15]}}, load_word[15:8]};
                        2'd2: rd_value = {{24{load_word[23]}}, load_word[23:16]};
                        default: rd_value = {{24{load_word[31]}}, load_word[31:24]};
                    endcase
                    3'b001: rd_value = dmem_addr[1] ?
                        {{16{load_word[31]}}, load_word[31:16]} :
                        {{16{load_word[15]}}, load_word[15:0]};
                    3'b010: rd_value = load_word;
                    3'b100: case (dmem_addr[1:0])
                        2'd0: rd_value = {24'd0, load_word[7:0]};
                        2'd1: rd_value = {24'd0, load_word[15:8]};
                        2'd2: rd_value = {24'd0, load_word[23:16]};
                        default: rd_value = {24'd0, load_word[31:24]};
                    endcase
                    3'b101: rd_value = dmem_addr[1] ?
                        {16'd0, load_word[31:16]} : {16'd0, load_word[15:0]};
                endcase
            end
            7'b0100011: begin
                dmem_addr = rs1_value + imm_s;
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
                    3'b101: rd_value = imem_rdata[30] ?
                        $signed(rs1_value) >>> imem_rdata[24:20] :
                        rs1_value >> imem_rdata[24:20];
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
                    3'b101: rd_value = funct7[5] ? $signed(rs1_value) >>> rs2_value[4:0] :
                                                   rs1_value >> rs2_value[4:0];
                    3'b110: rd_value = rs1_value | rs2_value;
                    3'b111: rd_value = rs1_value & rs2_value;
                endcase
            end
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            pc <= 32'd0;
            for (index = 0; index < 32; index = index + 1)
                registers[index] <= 32'd0;
        end else begin
            pc <= next_pc;
            if (write_rd && rd != 0)
                registers[rd] <= rd_value;
            registers[0] <= 32'd0;
        end
    end
endmodule
