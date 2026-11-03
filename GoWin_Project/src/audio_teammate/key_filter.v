`timescale 1ns/1ps

module key_filter #(
    parameter integer STABLE_CYCLES = 122880
)(
    input wire clk, rst, key_n,
    output reg key_down
);
    localparam integer COUNT_BITS = STABLE_CYCLES > 1 ? $clog2(STABLE_CYCLES) : 1;
    reg key_meta, key_sync;
    reg [COUNT_BITS-1:0] count;

    always @(posedge clk) begin
        if (rst) begin
            key_meta <= 1'b1;
            key_sync <= 1'b1;
        end else begin
            key_meta <= key_n;
            key_sync <= key_meta;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            count <= 0;
            key_down <= 0;
        end else if (!key_sync == key_down) begin
            count <= 0;
        end else if (count == STABLE_CYCLES - 1) begin
            count <= 0;
            key_down <= !key_sync;
        end else begin
            count <= count + 1'b1;
        end
    end
endmodule
