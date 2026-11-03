`timescale 1ns/1ps

// I2S slave receiver used by the visualisation co-processor board.
//
// Source stream: max98357_tx / i2s_tx_buffered on the audio board.
//   BCLK  = 6.144 MHz (96 kHz * 64), generated from audio_clk 24.576 MHz / 2
//   LRC   = 96 kHz, 32 BCLK slots per channel
//   SD    = Philips I2S, MSB first, one BCLK of delay after the LRC edge,
//           16 payload bits followed by 16 zero bits
//
// BCLK/LRC/SD are asynchronous to clk, so BCLK is oversampled (50 MHz gives
// about 8 samples per bit) and the payload is sampled on the BCLK rising
// edge, which sits in the middle of the stable data eye.
//
// One sample_stb pulse is emitted per LRC period (96 kHz) at the end of the
// right-hand slot, by which time both left and right registers hold the
// same frame. The audio board currently transmits identical L/R data.
module i2s_rx #(
    // A stream that stops must be distinguishable from a silent one.
    // 250000 clocks is 5 ms at 50 MHz.
    parameter integer TIMEOUT_CLKS = 250000
)(
    input  wire               clk,
    input  wire               reset_n,
    input  wire               bclk,
    input  wire               lrc,
    input  wire               sd,
    output reg  signed [15:0] left,
    output reg  signed [15:0] right,
    output reg                sample_stb,
    output reg                link_alive,
    output reg                align_error,
    output reg  [31:0]        frame_count,
    output reg  [15:0]        pad_residue
);
    localparam integer IDLE_W = (TIMEOUT_CLKS < 2) ? 1 : $clog2(TIMEOUT_CLKS + 1);

    // Two-stage synchronisers, one per wire.  The three inputs share a bus in
    // practice, but they are separate physical pins and are treated as such.
    (* async_reg = "true" *) reg [1:0] bclk_meta;
    (* async_reg = "true" *) reg [1:0] lrc_meta;
    (* async_reg = "true" *) reg [1:0] sd_meta;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            bclk_meta <= 2'b00;
            lrc_meta  <= 2'b00;
            sd_meta   <= 2'b00;
        end else begin
            bclk_meta <= {bclk_meta[0], bclk};
            lrc_meta  <= {lrc_meta[0],  lrc};
            sd_meta   <= {sd_meta[0],   sd};
        end
    end

    wire bclk_i = bclk_meta[1];
    wire lrc_i  = lrc_meta[1];
    wire sd_i   = sd_meta[1];

    reg        bclk_d;
    reg        lrc_d;
    reg [4:0]  bit_index;
    reg [15:0] shift_reg;
    reg        in_right;
    reg [4:0]  pad_count;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            bclk_d      <= 1'b0;
            lrc_d       <= 1'b0;
            bit_index   <= 5'd0;
            shift_reg   <= 16'd0;
            in_right    <= 1'b0;
            pad_count   <= 5'd0;
            left        <= 16'sd0;
            right       <= 16'sd0;
            sample_stb  <= 1'b0;
            align_error <= 1'b0;
            pad_residue <= 16'd0;
        end else begin
            bclk_d     <= bclk_i;
            sample_stb <= 1'b0;

            if (bclk_i && !bclk_d) begin
                if (lrc_i != lrc_d) begin
                    // First rising edge of a new half frame.  Philips I2S
                    // places the MSB one BCLK later, so this edge carries no
                    // payload and only re-arms the bit counter.
                    lrc_d     <= lrc_i;
                    in_right  <= lrc_i;
                    bit_index <= 5'd0;
                    if (pad_count != 5'd0) begin
                        // Payload bits leaked into the zero pad: the frame is
                        // off by at least one bit.
                        align_error <= 1'b1;
                        pad_residue <= {11'd0, pad_count};
                    end
                    pad_count <= 5'd0;
                end else begin
                    bit_index <= bit_index + 5'd1;
                    // bit_index counts payload bits already shifted: the edge
                    // that follows the frame boundary carries the MSB.
                    if (bit_index < 5'd16) begin
                        shift_reg <= {shift_reg[14:0], sd_i};
                        if (bit_index == 5'd15) begin
                            if (in_right) begin
                                right      <= {shift_reg[14:0], sd_i};
                                sample_stb <= 1'b1;
                            end else begin
                                left <= {shift_reg[14:0], sd_i};
                            end
                        end
                    end else begin
                        pad_count <= pad_count + {4'd0, sd_i};
                    end
                end
            end
        end
    end

    // Liveness: absence of BCLK must not look like a held note.
    reg [IDLE_W-1:0] idle_count;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            idle_count  <= {IDLE_W{1'b0}};
            link_alive  <= 1'b0;
            frame_count <= 32'd0;
        end else if (sample_stb) begin
            idle_count  <= {IDLE_W{1'b0}};
            link_alive  <= 1'b1;
            frame_count <= frame_count + 32'd1;
        end else if (idle_count != TIMEOUT_CLKS) begin
            idle_count <= idle_count + 1'b1;
        end else begin
            link_alive <= 1'b0;
        end
    end
endmodule
