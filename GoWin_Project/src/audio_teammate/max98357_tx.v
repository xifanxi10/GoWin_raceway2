`timescale 1ns / 1ps
// PCM source and this module use the SAME audio clock domain.
// Fixed 32-bit slots, MSB-aligned payload with zero padding.
module max98357_tx #(
    parameter integer DATA_WIDTH = 16,
    parameter integer SAMPLE_RATE = 48000,
    parameter integer AUDIO_CLK_HZ = 24576000
)(
    input   wire                         clk        ,
    input   wire                         rst        ,
    input   wire signed [DATA_WIDTH-1:0]  pcm_left   ,
    input   wire signed [DATA_WIDTH-1:0]  pcm_right  ,
    input   wire                         pcm_valid  ,
    output  wire                         pcm_ready  ,
    output  reg                          bclk       ,
    output  reg                          lrclk      ,
    output  wire                         din
);

localparam integer HALF_DIV = AUDIO_CLK_HZ / (SAMPLE_RATE * 128);
localparam integer DIV_BITS = HALF_DIV > 1 ? $clog2(HALF_DIV) : 1;

reg [DIV_BITS-1:0] divider;
reg [5:0] slot_bit;


generate
    if ((DATA_WIDTH != 16 && DATA_WIDTH != 24 && DATA_WIDTH != 32) ||
        (SAMPLE_RATE != 8000 && SAMPLE_RATE != 16000 &&
         SAMPLE_RATE != 32000 && SAMPLE_RATE != 44100 &&
         SAMPLE_RATE != 48000 && SAMPLE_RATE != 88200 && SAMPLE_RATE != 96000) ||
        HALF_DIV < 2 || AUDIO_CLK_HZ % (SAMPLE_RATE * 128) != 0) begin : invalid
        INVALID_MAX98357_PARAMETERS invalid_configuration();
    end
endgenerate


always @(posedge clk) begin
    if (rst) begin
        divider  <= 0;
        slot_bit <= 63;
        bclk     <= 0;
        lrclk    <= 1;
    end else if (divider == HALF_DIV-1) begin
        divider <= 0;
        bclk    <= ~bclk;
        if (bclk) begin
            slot_bit <= slot_bit + 1'b1;
            if (slot_bit == 63)
                lrclk <= 0;
            else if (slot_bit == 31)
                lrclk <= 1;
        end
    end else
        divider <= divider + 1'b1;
end


i2s_tx_buffered #(
    .WIDTH          (DATA_WIDTH     )
) serializer (
    .clk            (clk            ),
    .rst            (rst            ),
    .input_l_tdata  (pcm_left       ),
    .input_r_tdata  (pcm_right      ),
    .input_tvalid   (pcm_valid      ),
    .input_tready   (pcm_ready      ),
    .sck            (bclk           ),
    .ws             (lrclk          ),
    .sd             (din            )
);

endmodule
