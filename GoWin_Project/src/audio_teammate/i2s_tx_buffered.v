/*

Copyright (c) 2015 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Modified from alexforencich/verilog-dsp rtl/i2s_tx.v.
// Changes: atomic stereo frame buffer, zero on underrun and after payload,
// reset-aware ready, initial WS=1. sck/ws MUST be synchronous to clk;
// the BCLK half-period must contain at least two clk cycles.
`timescale 1ns / 1ps
module i2s_tx_buffered #(
    parameter WIDTH = 16
)(
    input   wire              clk            ,
    input   wire              rst            ,
    input   wire [WIDTH-1:0]   input_l_tdata  ,
    input   wire [WIDTH-1:0]   input_r_tdata  ,
    input   wire              input_tvalid   ,
    output  wire              input_tready   ,
    input   wire              sck            ,
    input   wire              ws             ,
    output  wire              sd
);

reg [WIDTH-1:0] l_data_reg, r_data_reg, active_right, sreg;
reg pair_valid;
reg [$clog2(WIDTH+1)-1:0] bit_cnt;
reg last_sck, last_ws, sd_reg;

assign input_tready = !rst && !pair_valid;
assign sd = sd_reg;


always @(posedge clk) begin
    if (rst) begin
        l_data_reg   <= 0;
        r_data_reg   <= 0;
        active_right <= 0;
        pair_valid   <= 0;
        sreg         <= 0;
        bit_cnt      <= 0;
        last_sck     <= 0;
        last_ws      <= 1;
        sd_reg       <= 0;
    end else begin
        if (input_tready && input_tvalid) begin
            l_data_reg <= input_l_tdata;
            r_data_reg <= input_r_tdata;
            pair_valid <= 1;
        end

        last_sck <= sck;

        if (!last_sck && sck) begin
            last_ws <= ws;
            if (last_ws != ws) begin
                bit_cnt <= WIDTH;
                if (ws) begin
                    sreg <= active_right;
                end else begin
                    // Snapshot BOTH channels at the left boundary.
                    // An input accepted on this same cycle belongs to a later frame.
                    sreg         <= pair_valid ? l_data_reg : {WIDTH{1'b0}};
                    active_right <= pair_valid ? r_data_reg : {WIDTH{1'b0}};
                    if (pair_valid)
                        pair_valid <= 0;
                end
            end
        end

        if (last_sck && !sck) begin
            if (bit_cnt > 0) begin
                bit_cnt       <= bit_cnt - 1'b1;
                {sd_reg, sreg} <= {sreg, 1'b0};
            end else begin
                sd_reg <= 0;
            end
        end
    end
end

endmodule
