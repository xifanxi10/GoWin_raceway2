`timescale 1ns/1ps

// One snapshot per sample_tick. Scan voices over CHANNELS clocks, then gain
// and saturate. Requires at least CHANNELS+4 clocks between sample ticks.
module adaptive_voice_mixer #(
    parameter integer CHANNELS = 20,
    parameter integer ACTIVE_THRESHOLD = 32,
    parameter integer QUIET_SAMPLES = 1024,
    parameter integer GAIN_DOWN_STEP = 64,
    parameter integer GAIN_UP_STEP = 8
)(
    input wire clk, rst, sample_tick,
    input wire [CHANNELS*16-1:0] samples,
    output reg signed [15:0] pcm,
    output reg [4:0] active_count,
    output reg [15:0] gain_q15,
    output reg clipped
);
    localparam integer HW = $clog2(QUIET_SAMPLES + 1);
    localparam IDLE = 0, SCAN = 1, GAIN = 2, PRODUCT = 3, OUTPUT = 4;
    reg [2:0] state;
    reg [CHANNELS*16-1:0] snapshot;
    reg [4:0] index, count;
    reg [HW-1:0] hold_count [0:CHANNELS-1];
    reg signed [20:0] sum;
    reg signed [37:0] product;
    wire signed [15:0] current_sample = snapshot[15:0];
    wire [15:0] magnitude = current_sample[15] ? (~current_sample + 16'd1) : current_sample;
    wire sounding = magnitude >= ACTIVE_THRESHOLD || hold_count[index] != 0;
    wire signed [37:0] scaled = product >>> 15;
    wire [15:0] target = target_gain(count);

    function [15:0] target_gain;
        input [4:0] n;
        begin
            // Q1.15 approximation of 1/sqrt(N), unity when silent or solo.
            case (n)
                0,1: target_gain=32768;
                2: target_gain=23170;
                3: target_gain=18919;
                4: target_gain=16384;
                5: target_gain=14654;
                6: target_gain=13377;
                7: target_gain=12385;
                8: target_gain=11585;
                9: target_gain=10923;
                10: target_gain=10362;
                11: target_gain=9880;
                12: target_gain=9459;
                13: target_gain=9088;
                14: target_gain=8758;
                15: target_gain=8461;
                16: target_gain=8192;
                17: target_gain=7947;
                18: target_gain=7723;
                19: target_gain=7517;
                default: target_gain=7327;
            endcase
        end
    endfunction

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            pcm <= 0;
            active_count <= 0;
            gain_q15 <= 32768;
            clipped <= 0;
            state <= IDLE;
            snapshot <= 0;
            index <= 0;
            count <= 0;
            sum <= 0;
            product <= 0;
            for (i=0; i<CHANNELS; i=i+1)
                hold_count[i] <= 0;
        end else begin
            case (state)
                IDLE: if (sample_tick) begin
                    snapshot <= samples;
                    index <= 0;
                    count <= 0;
                    sum <= 0;
                    state <= SCAN;
                end
                SCAN: begin
                    sum <= sum + {{5{current_sample[15]}}, current_sample};
                    if (magnitude >= ACTIVE_THRESHOLD)
                        hold_count[index] <= QUIET_SAMPLES;
                    else if (hold_count[index] != 0)
                        hold_count[index] <= hold_count[index] - 1'b1;
                    if (sounding)
                        count <= count + 1'b1;
                    snapshot <= snapshot >> 16;
                    if (index == CHANNELS-1)
                        state <= GAIN;
                    else
                        index <= index + 1'b1;
                end
                GAIN: begin
                    active_count <= count;
                    if (gain_q15 > target)
                        gain_q15 <= (gain_q15-target > GAIN_DOWN_STEP) ? gain_q15-GAIN_DOWN_STEP : target;
                    else if (gain_q15 < target)
                        gain_q15 <= (target-gain_q15 > GAIN_UP_STEP) ? gain_q15+GAIN_UP_STEP : target;
                    state <= PRODUCT;
                end
                PRODUCT: begin
                    product <= sum * $signed({1'b0,gain_q15});
                    state <= OUTPUT;
                end
                OUTPUT: begin
                    clipped <= 0;
                    if (scaled > 32767) begin
                        pcm <= 16'sh7fff;
                        clipped <= 1;
                    end else if (scaled < -32768) begin
                        pcm <= 16'sh8000;
                        clipped <= 1;
                    end else
                        pcm <= scaled[15:0];
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    // synthesis translate_off
    initial begin
        if (CHANNELS<1 || CHANNELS>20 || QUIET_SAMPLES<1 || ACTIVE_THRESHOLD<1 ||
            ACTIVE_THRESHOLD>32767 || GAIN_DOWN_STEP<1 || GAIN_UP_STEP<1)
            $fatal(1,"Invalid mixer parameters");
    end
    always @(posedge clk)
        if (!rst && sample_tick && state!=IDLE)
            $fatal(1,"Mixer sample period too short");
    // synthesis translate_on
endmodule


// Exact pcm * gain / 1000, using serial shift/add and division (no extra DSP).
// One-sample pipeline latency; requires 40 clocks between sample ticks.
module master_volume (
    input wire clk,
    input wire rst,
    input wire sample_tick,
    input wire [9:0] gain,
    input wire signed [15:0] pcm_in,
    output reg signed [15:0] pcm_out
);
    reg [9:0] actual_gain;
    wire [9:0] target_gain = gain > 1000 ? 10'd1000 : gain;
    wire [9:0] next_gain = actual_gain < target_gain ?
        ((target_gain-actual_gain > 4) ? actual_gain+10'd4 : target_gain) :
        ((actual_gain-target_gain > 4) ? actual_gain-10'd4 : target_gain);
    reg [1:0] state;
    reg negative;
    reg [25:0] multiplicand, accumulator, quotient;
    reg [9:0] multiplier;
    reg [10:0] remainder;
    reg [5:0] bits_left;
    wire [10:0] trial = {remainder[9:0],quotient[25]};
    wire [25:0] divided = {quotient[24:0],trial >= 1000};
    always @(posedge clk) begin
        if (rst) begin
            actual_gain <= 0;
            pcm_out <= 0;
            state <= 0;
            negative <= 0;
            multiplicand <= 0;
            accumulator <= 0;
            quotient <= 0;
            multiplier <= 0;
            remainder <= 0;
            bits_left <= 0;
        end else if (sample_tick) begin
            actual_gain <= next_gain;
            negative <= pcm_in[15];
            multiplicand <= {10'd0,(pcm_in[15] ? (~pcm_in + 16'd1) : pcm_in)};
            multiplier <= next_gain;
            accumulator <= 0;
            bits_left <= 10;
            state <= 1;
        end else case (state)
            1: begin
                if (multiplier[0]) accumulator <= accumulator + multiplicand;
                multiplicand <= multiplicand << 1;
                multiplier <= multiplier >> 1;
                bits_left <= bits_left - 1'b1;
                if (bits_left == 1) state <= 2;
            end
            2: begin
                quotient <= accumulator;
                remainder <= 0;
                bits_left <= 26;
                state <= 3;
            end
            3: begin
                remainder <= trial >= 1000 ? trial-11'd1000 : trial;
                quotient <= divided;
                bits_left <= bits_left - 1'b1;
                if (bits_left == 1) begin
                    pcm_out <= negative ? -$signed(divided[15:0]) : $signed(divided[15:0]);
                    state <= 0;
                end
            end
            default: state <= 0;
        endcase
    end
endmodule
