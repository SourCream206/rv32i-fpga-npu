module npu_peripheral (
    input  logic                    clk,
    input  logic                    rst,
    input  logic                    bus_we,
    input  logic [3:0]              bus_byte_enable,
    input  logic [31:0]             bus_addr,
    input  logic [31:0]             bus_wdata,
    output logic [31:0]             bus_rdata,
    input  logic                    input_bank_we,
    input  logic [3:0]              input_bank_addr,
    input  logic signed [7:0]       input_bank_wdata,
    input  logic [3:0]              output_bank_addr,
    output logic signed [7:0]       output_bank_rdata
);

    localparam logic [5:2] CONTROL     = 4'h0;
    localparam logic [5:2] STATUS      = 4'h1;
    localparam logic [5:2] INPUT_ADDR  = 4'h2;
    localparam logic [5:2] INPUT_DATA  = 4'h3;
    localparam logic [5:2] WEIGHT_ADDR = 4'h4;
    localparam logic [5:2] WEIGHT_DATA = 4'h5;
    localparam logic [5:2] BIAS_ADDR   = 4'h6;
    localparam logic [5:2] BIAS_DATA   = 4'h7;
    localparam logic [5:2] SCALE       = 4'h8;
    localparam logic [5:2] OUTPUT_ADDR = 4'h9;
    localparam logic [5:2] OUTPUT_DATA = 4'hA;
    localparam logic [5:2] SOFTMAX_DATA = 4'hB;
    localparam logic [5:2] SHIFT_REG    = 4'hC;

    typedef enum logic [3:0] {
        IDLE,
        INITIALIZE,
        TILE_CLEAR,
        TILE_EXECUTE,
        TILE_WRITEBACK,
        SOFTMAX_INIT,
        SOFTMAX_FIND_MAX,
        SOFTMAX_MAX_READY,
        SOFTMAX_BUILD,
        SOFTMAX_SUM_READY,
        SOFTMAX_NORMALIZE,
        DONE
    } npu_state_t;

    (* ramstyle = "M9K" *) logic signed [7:0] w_mem [0:255];
    (* ramstyle = "M9K" *) logic signed [7:0] in_mem [0:15];
    (* ramstyle = "M9K" *) logic signed [7:0] act_mem [0:15];
    logic signed [7:0] bias_mem [0:15];
    logic signed [31:0] projection_accum [0:15];
    logic [15:0] softmax_output [0:15];
    logic [15:0] softmax_numerator [0:15];

    npu_state_t state;
    logic [3:0] input_address;
    logic [7:0] weight_address;
    logic [3:0] bias_address;
    logic [3:0] output_address;
    logic [3:0] output_tile;
    logic [3:0] input_tile;
    logic signed [5:0] projection_shift;
    logic [3:0] softmax_shift;
    logic apply_gelu;
    logic apply_softmax;
    logic [3:0] softmax_index;
    logic signed [31:0] softmax_max;
    logic [20:0] softmax_sum;

    logic signed [7:0] mac_activations [0:3];
    logic signed [7:0] mac_weights [0:3][0:3];
    logic signed [31:0] tile_accumulators [0:3];
    logic signed [31:0] tile_totals [0:3];
    logic mac_clear;
    logic mac_enable;

    function automatic logic signed [7:0] quantize_activation(
        input logic signed [31:0] value,
        input logic signed [5:0] shift,
        input logic gelu
    );
        logic signed [63:0] shifted;
        logic signed [63:0] extended_value;
        begin
            extended_value = value;
            if (shift >= 0)
                shifted = extended_value >>> shift;
            else
                shifted = extended_value <<< -shift;
            if (gelu && (shifted < 0))
                quantize_activation = 8'sd0;
            else if (shifted > 127)
                quantize_activation = 8'sd127;
            else if (shifted < -128)
                quantize_activation = 8'sh80;
            else
                quantize_activation = shifted[7:0];
        end
    endfunction

    function automatic logic [5:0] softmax_lut_index(
        input logic signed [31:0] maximum,
        input logic signed [7:0] value,
        input logic [3:0] shift
    );
        logic signed [31:0] delta;
        logic signed [31:0] scaled_delta;
        begin
            delta = maximum - value;
            scaled_delta = delta >>> shift;
            if (scaled_delta < 0)
                softmax_lut_index = 6'd0;
            else if (scaled_delta > 63)
                softmax_lut_index = 6'd63;
            else
                softmax_lut_index = scaled_delta[5:0];
        end
    endfunction

    function automatic logic [15:0] softmax_lut(input logic [5:0] index);
        begin
            case (index)
                6'd0: softmax_lut = 16'd65535; 6'd1: softmax_lut = 16'd61564;
                6'd2: softmax_lut = 16'd57834; 6'd3: softmax_lut = 16'd54330;
                6'd4: softmax_lut = 16'd51039; 6'd5: softmax_lut = 16'd47946;
                6'd6: softmax_lut = 16'd45042; 6'd7: softmax_lut = 16'd42313;
                6'd8: softmax_lut = 16'd39749; 6'd9: softmax_lut = 16'd37341;
                6'd10: softmax_lut = 16'd35078; 6'd11: softmax_lut = 16'd32953;
                6'd12: softmax_lut = 16'd30957; 6'd13: softmax_lut = 16'd29081;
                6'd14: softmax_lut = 16'd27319; 6'd15: softmax_lut = 16'd25664;
                6'd16: softmax_lut = 16'd24109; 6'd17: softmax_lut = 16'd22648;
                6'd18: softmax_lut = 16'd21276; 6'd19: softmax_lut = 16'd19987;
                6'd20: softmax_lut = 16'd18776; 6'd21: softmax_lut = 16'd17639;
                6'd22: softmax_lut = 16'd16570; 6'd23: softmax_lut = 16'd15566;
                6'd24: softmax_lut = 16'd14623; 6'd25: softmax_lut = 16'd13737;
                6'd26: softmax_lut = 16'd12905; 6'd27: softmax_lut = 16'd12123;
                6'd28: softmax_lut = 16'd11388; 6'd29: softmax_lut = 16'd10698;
                6'd30: softmax_lut = 16'd10050; 6'd31: softmax_lut = 16'd9441;
                6'd32: softmax_lut = 16'd8869; 6'd33: softmax_lut = 16'd8332;
                6'd34: softmax_lut = 16'd7827; 6'd35: softmax_lut = 16'd7353;
                6'd36: softmax_lut = 16'd6907; 6'd37: softmax_lut = 16'd6489;
                6'd38: softmax_lut = 16'd6096; 6'd39: softmax_lut = 16'd5726;
                6'd40: softmax_lut = 16'd5379; 6'd41: softmax_lut = 16'd5054;
                6'd42: softmax_lut = 16'd4747; 6'd43: softmax_lut = 16'd4460;
                6'd44: softmax_lut = 16'd4190; 6'd45: softmax_lut = 16'd3936;
                6'd46: softmax_lut = 16'd3697; 6'd47: softmax_lut = 16'd3473;
                6'd48: softmax_lut = 16'd3263; 6'd49: softmax_lut = 16'd3065;
                6'd50: softmax_lut = 16'd2879; 6'd51: softmax_lut = 16'd2705;
                6'd52: softmax_lut = 16'd2541; 6'd53: softmax_lut = 16'd2387;
                6'd54: softmax_lut = 16'd2242; 6'd55: softmax_lut = 16'd2107;
                6'd56: softmax_lut = 16'd1979; 6'd57: softmax_lut = 16'd1859;
                6'd58: softmax_lut = 16'd1746; 6'd59: softmax_lut = 16'd1641;
                6'd60: softmax_lut = 16'd1541; 6'd61: softmax_lut = 16'd1448;
                6'd62: softmax_lut = 16'd1360; default: softmax_lut = 16'd1278;
            endcase
        end
    endfunction

    function automatic logic [15:0] normalize_softmax(
        input logic [15:0] numerator,
        input logic [20:0] denominator
    );
        logic [63:0] dividend;
        begin
            dividend = {48'd0, numerator} * 16'd65535;
            normalize_softmax = dividend / denominator;
        end
    endfunction

    genvar lane;
    genvar row;
    genvar column;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : generate_lanes
            assign mac_activations[lane] = in_mem[input_tile * 4 + lane];
            assign tile_totals[lane] =
                projection_accum[output_tile * 4 + lane] + tile_accumulators[lane];
        end
        for (row = 0; row < 4; row = row + 1) begin : generate_rows
            for (column = 0; column < 4; column = column + 1) begin : generate_columns
                assign mac_weights[row][column] =
                    w_mem[(output_tile * 4 + row) * 16 + input_tile * 4 + column];
            end
        end
    endgenerate

    assign mac_clear = (state == TILE_CLEAR);
    assign mac_enable = (state == TILE_EXECUTE);

    mac_array_4x4 mac_array (
        .clk(clk),
        .rst(rst),
        .clear(mac_clear),
        .enable(mac_enable),
        .activations(mac_activations),
        .weights(mac_weights),
        .accumulators(tile_accumulators)
    );

    integer index;
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            input_address <= '0;
            weight_address <= '0;
            bias_address <= '0;
            output_address <= '0;
            output_tile <= '0;
            input_tile <= '0;
            projection_shift <= '0;
            softmax_shift <= '0;
            apply_gelu <= 1'b0;
            apply_softmax <= 1'b0;
            softmax_index <= '0;
            softmax_max <= '0;
            softmax_sum <= '0;
        end else begin
            if (input_bank_we && ((state == IDLE) || (state == DONE)))
                in_mem[input_bank_addr] <= input_bank_wdata;

            case (state)
                INITIALIZE: begin
                    for (index = 0; index < 16; index = index + 1)
                        projection_accum[index] <= {{24{bias_mem[index][7]}}, bias_mem[index]};
                    output_tile <= '0;
                    input_tile <= '0;
                    state <= TILE_CLEAR;
                end
                TILE_CLEAR: state <= TILE_EXECUTE;
                TILE_EXECUTE: state <= TILE_WRITEBACK;
                TILE_WRITEBACK: begin
                    for (index = 0; index < 4; index = index + 1)
                        projection_accum[output_tile * 4 + index] <= tile_totals[index];
                    if (input_tile == 4'd3) begin
                        for (index = 0; index < 4; index = index + 1)
                            act_mem[output_tile * 4 + index] <= quantize_activation(
                                tile_totals[index], projection_shift, apply_gelu
                            );
                        input_tile <= '0;
                        if (output_tile == 4'd3) begin
                            state <= apply_softmax ? SOFTMAX_INIT : DONE;
                        end else begin
                            output_tile <= output_tile + 1'b1;
                            state <= TILE_CLEAR;
                        end
                    end else begin
                        input_tile <= input_tile + 1'b1;
                        state <= TILE_CLEAR;
                    end
                end
                SOFTMAX_INIT: begin
                    softmax_index <= '0;
                    softmax_max <= -32'sd128;
                    state <= SOFTMAX_FIND_MAX;
                end
                SOFTMAX_FIND_MAX: begin
                    if ($signed(act_mem[softmax_index]) > softmax_max)
                        softmax_max <= $signed(act_mem[softmax_index]);
                    if (softmax_index == 4'd15)
                        state <= SOFTMAX_MAX_READY;
                    else
                        softmax_index <= softmax_index + 1'b1;
                end
                SOFTMAX_MAX_READY: begin
                    softmax_index <= '0;
                    softmax_sum <= '0;
                    state <= SOFTMAX_BUILD;
                end
                SOFTMAX_BUILD: begin
                    softmax_numerator[softmax_index] <= softmax_lut(
                        softmax_lut_index(
                            softmax_max, $signed(act_mem[softmax_index]), softmax_shift
                        )
                    );
                    softmax_sum <= softmax_sum + softmax_lut(
                        softmax_lut_index(
                            softmax_max, $signed(act_mem[softmax_index]), softmax_shift
                        )
                    );
                    if (softmax_index == 4'd15)
                        state <= SOFTMAX_SUM_READY;
                    else
                        softmax_index <= softmax_index + 1'b1;
                end
                SOFTMAX_SUM_READY: begin
                    softmax_index <= '0;
                    state <= SOFTMAX_NORMALIZE;
                end
                SOFTMAX_NORMALIZE: begin
                    softmax_output[softmax_index] <= normalize_softmax(
                        softmax_numerator[softmax_index], softmax_sum
                    );
                    if (softmax_index == 4'd15)
                        state <= DONE;
                    else
                        softmax_index <= softmax_index + 1'b1;
                end
                default: ;
            endcase

            if (bus_we && (bus_addr[31:16] == 16'h0006)) begin
                case (bus_addr[5:2])
                    CONTROL: begin
                        if (bus_wdata[1]) begin
                            state <= IDLE;
                        end else if (bus_wdata[0] && ((state == IDLE) || (state == DONE))) begin
                            apply_gelu <= bus_wdata[2];
                            apply_softmax <= bus_wdata[3];
                            state <= INITIALIZE;
                        end
                    end
                    INPUT_ADDR: if ((state == IDLE) || (state == DONE))
                        input_address <= bus_wdata[3:0];
                    INPUT_DATA: if ((state == IDLE) || (state == DONE)) begin
                        for (index = 0; index < 4; index = index + 1)
                            if (bus_byte_enable[index])
                                in_mem[(input_address + index) & 4'hF] <= bus_wdata[index * 8 +: 8];
                        input_address <= input_address + 4;
                    end
                    WEIGHT_ADDR: if ((state == IDLE) || (state == DONE))
                        weight_address <= bus_wdata[7:0];
                    WEIGHT_DATA: if ((state == IDLE) || (state == DONE)) begin
                        for (index = 0; index < 4; index = index + 1)
                            if (bus_byte_enable[index])
                                w_mem[weight_address + index] <= bus_wdata[index * 8 +: 8];
                        weight_address <= weight_address + 4;
                    end
                    BIAS_ADDR: if ((state == IDLE) || (state == DONE))
                        bias_address <= bus_wdata[3:0];
                    BIAS_DATA: if ((state == IDLE) || (state == DONE)) begin
                        for (index = 0; index < 4; index = index + 1)
                            if (bus_byte_enable[index])
                                bias_mem[(bias_address + index) & 4'hF] <= bus_wdata[index * 8 +: 8];
                        bias_address <= bias_address + 4;
                    end
                    SCALE: if ((state == IDLE) || (state == DONE)) begin
                        softmax_shift <= bus_wdata[11:8];
                    end
                    OUTPUT_ADDR: output_address <= bus_wdata[3:0];
                    SHIFT_REG: if ((state == IDLE) || (state == DONE))
                        projection_shift <= $signed(bus_wdata[5:0]);
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        output_bank_rdata = act_mem[output_bank_addr];
        bus_rdata = '0;
        if (bus_addr[31:16] == 16'h0006) begin
            case (bus_addr[5:2])
                STATUS:       bus_rdata = {30'd0, state == DONE, !((state == IDLE) || (state == DONE))};
                INPUT_ADDR:   bus_rdata = {28'd0, input_address};
                WEIGHT_ADDR:  bus_rdata = {24'd0, weight_address};
                BIAS_ADDR:    bus_rdata = {28'd0, bias_address};
                SCALE:        bus_rdata = {20'd0, softmax_shift, 8'd0};
                OUTPUT_ADDR:  bus_rdata = {28'd0, output_address};
                OUTPUT_DATA:  bus_rdata = {
                    act_mem[(output_address + 3) & 4'hF],
                    act_mem[(output_address + 2) & 4'hF],
                    act_mem[(output_address + 1) & 4'hF],
                    act_mem[output_address]
                };
                SOFTMAX_DATA: bus_rdata = {16'd0, softmax_output[output_address]};
                SHIFT_REG:    bus_rdata = {{26{projection_shift[5]}}, projection_shift};
                default:      bus_rdata = '0;
            endcase
        end
    end

endmodule
