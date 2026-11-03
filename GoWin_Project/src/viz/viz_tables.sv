`timescale 1ns/1ps

// CORDIC rotator in rotation mode, 16-bit binary angle (65536 == 2*pi).
//
// The requested angle is reduced to one quadrant (0..90 degrees) before the
// iterations and reconstructed afterwards, because CORDIC only converges while
// |z| stays below the sum of the atan() constants (99.88 degrees for 17
// iterations).
//
// Precision, measured against double-precision cos/sin over all 1024 twiddle
// angles: worst-case error 1.2 LSB of Q15 (0.002 degrees).  The starting
// vector is 1/CORDIC-gain, so the iteration gain cancels without a final
// multiply.
module cordic_rot #(
    parameter integer ITER = 17
)(
    input  wire               clk,
    input  wire               reset_n,
    input  wire               start,
    input  wire [15:0]        angle,
    output reg                busy,
    output reg                done,
    output reg  signed [15:0] cos_q15,
    output reg  signed [15:0] sin_q15
);
    // (1/1.6467602581) * 2^21, i.e. the Q21 stand-in for 1/CORDIC gain.
    localparam signed [23:0] X0 = 24'sd1273502;

    localparam [1:0] S_IDLE = 2'd0, S_ROT = 2'd1, S_OUT = 2'd2;

    // atan(2^-i) in 2^20 units per turn; four extra fraction bits keep the
    // residual angle below 1/16 of a 16-bit LSB.
    function automatic signed [20:0] atan_step(input [4:0] i);
        case (i)
            5'd0:  atan_step = 21'sd131072;
            5'd1:  atan_step = 21'sd77376;
            5'd2:  atan_step = 21'sd40884;
            5'd3:  atan_step = 21'sd20753;
            5'd4:  atan_step = 21'sd10417;
            5'd5:  atan_step = 21'sd5213;
            5'd6:  atan_step = 21'sd2607;
            5'd7:  atan_step = 21'sd1304;
            5'd8:  atan_step = 21'sd652;
            5'd9:  atan_step = 21'sd326;
            5'd10: atan_step = 21'sd163;
            5'd11: atan_step = 21'sd81;
            5'd12: atan_step = 21'sd41;
            5'd13: atan_step = 21'sd20;
            5'd14: atan_step = 21'sd10;
            5'd15: atan_step = 21'sd5;
            default: atan_step = 21'sd3;
        endcase
    endfunction

    function automatic signed [15:0] sat16(input signed [23:0] v);
        begin
            if (v > 24'sd32767) sat16 = 16'sh7fff;
            else if (v < -24'sd32768) sat16 = 16'sh8000;
            else sat16 = v[15:0];
        end
    endfunction

    reg [1:0]         state;
    reg [4:0]         iter;
    reg [1:0]         quad;
    reg signed [23:0] x, y;
    reg signed [20:0] z;

    wire signed [23:0] c_rot = (quad == 2'd0) ? x :
                               (quad == 2'd1) ? -y :
                               (quad == 2'd2) ? -x : y;
    wire signed [23:0] s_rot = (quad == 2'd0) ? y :
                               (quad == 2'd1) ? x :
                               (quad == 2'd2) ? -y : -x;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            iter    <= 5'd0;
            quad    <= 2'd0;
            x       <= 24'sd0;
            y       <= 24'sd0;
            z       <= 21'sd0;
            cos_q15 <= 16'sd0;
            sin_q15 <= 16'sd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    busy  <= 1'b1;
                    x     <= X0;
                    y     <= 24'sd0;
                    quad  <= angle[15:14];
                    // 0..90 degrees in 2^20 units
                    z     <= {3'b000, angle[13:0], 4'b0000};
                    iter  <= 5'd0;
                    state <= S_ROT;
                end
                S_ROT: begin
                    if (z >= 0) begin
                        x <= x - (y >>> iter);
                        y <= y + (x >>> iter);
                        z <= z - atan_step(iter);
                    end else begin
                        x <= x + (y >>> iter);
                        y <= y - (x >>> iter);
                        z <= z + atan_step(iter);
                    end
                    if (iter == ITER[4:0] - 5'd1) state <= S_OUT;
                    else iter <= iter + 5'd1;
                end
                S_OUT: begin
                    // Q21 -> Q15 with round-to-nearest
                    cos_q15 <= sat16((c_rot + 24'sd32) >>> 6);
                    sin_q15 <= sat16((s_rot + 24'sd32) >>> 6);
                    busy    <= 1'b0;
                    done    <= 1'b1;
                    state   <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// On-chip sine/cosine tables for the visualiser.
//
// After reset a single CORDIC rotor fills both tables once:
//
//   hann_ram[n] = 0.5 * (1 - cos(2*pi*n/2048)) * 32767   (Hann window, Q15)
//   tw_ram[k]   = {cos, sin}(-2*pi*k/2048)               (FFT twiddle, Q15)
//
// The twiddle table is half a circle on purpose: with real input only bins
// 0..N/2-1 are of interest, and the widest stage (len = 2048) needs
// e^(-j*2*pi*j/2048) for j = 0..1023.  Indexing every stage as
// j * 2048/len then keeps a single 1024-entry table valid for all 11 stages.
//
// Generating them on chip keeps the build free of ROM init files (Gowin
// resolves $readmemh paths relative to the project directory, which differs
// between the GUI, gw_sh and ModelSim) and makes the tables reproducible in
// simulation without shipping a binary blob.
module viz_tables #(
    parameter integer HANN_LEN = 2048,
    parameter integer TW_LEN   = 1024
)(
    input  wire               clk,
    input  wire               reset_n,
    output reg                ready,
    input  wire [10:0]        hann_addr,
    output reg  [15:0]        hann_q15,
    input  wire [9:0]         tw_addr,
    output reg  signed [15:0] tw_cos,
    output reg  signed [15:0] tw_sin,
    output reg  [31:0]        init_cycles
);
    localparam [1:0] S_LAUNCH = 2'd0, S_WAIT = 2'd1, S_WRITE = 2'd2, S_DONE = 2'd3;

    reg [15:0] hann_ram [0:HANN_LEN-1];
    reg [31:0] tw_ram   [0:TW_LEN-1];

    always @(posedge clk) begin
        hann_q15 <= hann_ram[hann_addr];
        tw_cos   <= tw_ram[tw_addr][31:16];
        tw_sin   <= tw_ram[tw_addr][15:0];
    end

    reg [1:0]  state;
    reg        start;
    reg [15:0] angle;
    reg        phase;        // 0 = Hann window, 1 = twiddles
    reg [10:0] idx;
    wire       cordic_busy;
    wire       cordic_done;
    wire signed [15:0] c_val, s_val;

    cordic_rot u_cordic (
        .clk     (clk),
        .reset_n (reset_n),
        .start   (start),
        .angle   (angle),
        .busy    (cordic_busy),
        .done    (cordic_done),
        .cos_q15 (c_val),
        .sin_q15 (s_val)
    );

    // hann = 16384 - cos/2 reaches 32768 at the window centre; clamp to Q15.
    wire signed [15:0] c_half  = c_val >>> 1;
    wire signed [16:0] hann_s  = 17'sd16384 - {{1{c_half[15]}}, c_half};
    wire        [15:0] hann_val = (hann_s > 17'sd32767) ? 16'd32767 : hann_s[15:0];

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= S_LAUNCH;
            start       <= 1'b0;
            angle       <= 16'd0;
            phase       <= 1'b0;
            idx         <= 11'd0;
            ready       <= 1'b0;
            init_cycles <= 32'd0;
        end else begin
            start <= 1'b0;
            if (state != S_DONE) init_cycles <= init_cycles + 32'd1;
            case (state)
                S_LAUNCH: begin
                    start <= 1'b1;
                    // Hann: n * 2*pi/2048.  Twiddle: -k * 2*pi/2048 (half turn).
                    angle <= phase ? (-(idx[9:0] << 5)) : (idx[10:0] << 5);
                    state <= S_WAIT;
                end
                S_WAIT: if (cordic_done) state <= S_WRITE;
                S_WRITE: begin
                    if (!phase) begin
                        hann_ram[idx] <= hann_val;
                        if (idx == HANN_LEN-1) begin
                            phase <= 1'b1;
                            idx   <= 11'd0;
                        end else begin
                            idx <= idx + 11'd1;
                        end
                        state <= S_LAUNCH;
                    end else begin
                        tw_ram[idx[9:0]] <= {c_val, s_val};
                        if (idx == TW_LEN-1)
                            state <= S_DONE;
                        else begin
                            idx   <= idx + 11'd1;
                            state <= S_LAUNCH;
                        end
                    end
                end
                default: begin
                    ready <= 1'b1;
                    state <= S_DONE;
                end
            endcase
        end
    end
endmodule
