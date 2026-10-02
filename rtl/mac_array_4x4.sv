module mac_array_4x4 (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     clear,
    input  logic                     enable,
    input  logic signed [7:0]        activations [0:3],
    input  logic signed [7:0]        weights [0:3][0:3],
    output logic signed [31:0]       accumulators [0:3]
);

    logic signed [31:0] products [0:3][0:3];

    genvar row;
    genvar column;
    generate
        for (row = 0; row < 4; row = row + 1) begin : generate_rows
            for (column = 0; column < 4; column = column + 1) begin : generate_columns
                assign products[row][column] =
                    $signed(weights[row][column]) * $signed(activations[column]);
            end
        end
    endgenerate

    integer accumulator_index;
    always_ff @(posedge clk) begin
        if (rst || clear) begin
            for (accumulator_index = 0; accumulator_index < 4; accumulator_index = accumulator_index + 1)
                accumulators[accumulator_index] <= '0;
        end else if (enable) begin
            for (accumulator_index = 0; accumulator_index < 4; accumulator_index = accumulator_index + 1)
                accumulators[accumulator_index] <= accumulators[accumulator_index]
                    + products[accumulator_index][0]
                    + products[accumulator_index][1]
                    + products[accumulator_index][2]
                    + products[accumulator_index][3];
        end
    end

endmodule
