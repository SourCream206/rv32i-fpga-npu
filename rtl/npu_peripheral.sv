module npu_peripheral (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    bus_we,
    input  logic [3:0]              bus_byte_enable,
    input  logic [31:0]             bus_addr,
    input  logic [31:0]             bus_wdata,
    output logic [31:0]             bus_rdata
);

    localparam logic [5:2] CONTROL     = 4'h0;
    localparam logic [5:2] STATUS      = 4'h1;
    localparam logic [5:2] INPUT0      = 4'h2;
    localparam logic [5:2] WEIGHT_ADDR = 4'h4;
    localparam logic [5:2] WEIGHT_DATA = 4'h5;
    localparam logic [5:2] ACCUM0      = 4'h8;
    localparam logic [5:2] ACCUM1      = 4'h9;
    localparam logic [5:2] ACCUM2      = 4'hA;
    localparam logic [5:2] ACCUM3      = 4'hB;

    typedef enum logic [1:0] {
        IDLE,
        CLEAR,
        EXECUTE,
        DONE
    } npu_state_t;

    npu_state_t state;
    logic [31:0] input_vector;
    logic [3:0] weight_address;
    logic signed [7:0] weight_ram [0:15];
    logic signed [7:0] activations [0:3];
    logic signed [7:0] weights [0:3][0:3];
    logic signed [31:0] accumulators [0:3];
    logic mac_clear;
    logic mac_enable;
    logic busy;
    logic done;

    genvar lane;
    genvar row;
    genvar column;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : generate_activations
            assign activations[lane] = input_vector[lane * 8 +: 8];
        end
        for (row = 0; row < 4; row = row + 1) begin : generate_rows
            for (column = 0; column < 4; column = column + 1) begin : generate_columns
                assign weights[row][column] = weight_ram[row * 4 + column];
            end
        end
    endgenerate

    assign busy = (state == CLEAR) || (state == EXECUTE);
    assign done = (state == DONE);

    mac_array_4x4 mac_array (
        .clk(clk),
        .rst(rst),
        .clear(mac_clear),
        .enable(mac_enable),
        .activations(activations),
        .weights(weights),
        .accumulators(accumulators)
    );

    integer index;
    always_ff @(posedge clk) begin
        mac_clear <= 1'b0;
        mac_enable <= 1'b0;

        if (rst) begin
            state <= IDLE;
            input_vector <= '0;
            weight_address <= '0;
            for (index = 0; index < 16; index = index + 1)
                weight_ram[index] <= '0;
        end else begin
            case (state)
                CLEAR: begin
                    mac_clear <= 1'b1;
                    state <= EXECUTE;
                end
                EXECUTE: begin
                    mac_enable <= 1'b1;
                    state <= DONE;
                end
                default: ;
            endcase

            if (bus_we && (bus_addr[31:16] == 16'h0006)) begin
                case (bus_addr[5:2])
                    CONTROL: begin
                        if (bus_wdata[1]) begin
                            state <= IDLE;
                            mac_clear <= 1'b1;
                        end else if (bus_wdata[0] && !busy) begin
                            state <= CLEAR;
                        end
                    end
                    INPUT0: begin
                        if (!busy) begin
                            for (index = 0; index < 4; index = index + 1)
                                if (bus_byte_enable[index])
                                    input_vector[index * 8 +: 8] <= bus_wdata[index * 8 +: 8];
                        end
                    end
                    WEIGHT_ADDR: begin
                        if (!busy && bus_byte_enable[0])
                            weight_address <= bus_wdata[3:0];
                    end
                    WEIGHT_DATA: begin
                        if (!busy) begin
                            for (index = 0; index < 4; index = index + 1)
                                if (bus_byte_enable[index])
                                    weight_ram[(weight_address + index) & 4'hF]
                                        <= bus_wdata[index * 8 +: 8];
                            weight_address <= weight_address + 4;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        bus_rdata = '0;
        if (bus_addr[31:16] == 16'h0006) begin
            case (bus_addr[5:2])
                STATUS:      bus_rdata = {30'd0, done, busy};
                INPUT0:      bus_rdata = input_vector;
                WEIGHT_ADDR: bus_rdata = {28'd0, weight_address};
                ACCUM0:      bus_rdata = accumulators[0];
                ACCUM1:      bus_rdata = accumulators[1];
                ACCUM2:      bus_rdata = accumulators[2];
                ACCUM3:      bus_rdata = accumulators[3];
                default:     bus_rdata = '0;
            endcase
        end
    end

endmodule
