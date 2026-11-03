`timescale 1ns/1ps

// Lissajous ("phase portrait") scope.
//
// X = x[n], Y = x[n - T/4], where T is the period the trigger scanner measured
// between two consecutive rising zero crossings.  A single tone therefore draws
// a stable circle or ellipse instead of the diagonal line a zero delay would
// give, and the trace does not rotate between frames because both the trigger
// point and the delay are re-measured from the same captured bank.
//
// Two passes over the bank: the first stores the X byte of each point, the
// second pairs it with the delayed Y byte.  256 consecutive samples span about
// 2.7 ms, enough for a couple of periods of a mid-range note.
module xy_scope #(
    parameter integer DEPTH         = 2048,
    parameter integer AW            = 11,
    parameter integer POINTS        = 256,
    parameter integer DEFAULT_DELAY = 64
)(
    input  wire               clk,
    input  wire               reset_n,
    input  wire               start,
    input  wire [AW-1:0]      trig_index,
    input  wire [15:0]        period_est,
    output reg                busy,
    output reg                done,
    output wire [AW-1:0]      rd_addr,
    input  wire signed [15:0] rd_data,
    output reg                wr_en,
    output reg  [7:0]         wr_addr,
    output reg  [7:0]         wr_x,
    output reg  [7:0]         wr_y
);
    localparam [1:0] S_IDLE = 2'd0, S_X = 2'd1, S_Y = 2'd2, S_FIN = 2'd3;

    function automatic [7:0] enc8(input signed [15:0] v);
        reg signed [8:0] t;
        begin
            t    = {{1{v[15]}}, v[15:8]} + 9'sd128;
            enc8 = t[7:0];
        end
    endfunction

    reg [1:0]  state;
    reg [AW-1:0] c;
    reg        dv;
    reg [AW-1:0] t0;
    reg [AW-1:0] delay;
    reg [7:0]  x_ram [0:POINTS-1];
    reg [7:0]  x_q;
    reg [7:0]  x_addr;

    wire [15:0] quarter = period_est >> 2;

    assign rd_addr = (state == S_Y) ? (t0 + c[AW-1:0] - delay)
                                    : (t0 + c[AW-1:0]);

    always @(posedge clk) begin
        x_q <= x_ram[x_addr[7:0]];
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            c       <= {AW{1'b0}};
            dv      <= 1'b0;
            t0      <= {AW{1'b0}};
            delay   <= DEFAULT_DELAY[AW-1:0];
            x_addr  <= 8'd0;
            wr_en   <= 1'b0;
            wr_addr <= 8'd0;
            wr_x    <= 8'd0;
            wr_y    <= 8'd0;
        end else begin
            dv      <= 1'b0;
            wr_en   <= 1'b0;
            done    <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy  <= 1'b1;
                        t0    <= trig_index;
                        // Quarter-period delay, clamped to something sane.
                        delay <= (period_est == 16'd0 || quarter == 16'd0) ?
                                 DEFAULT_DELAY[AW-1:0] : quarter[AW-1:0];
                        c     <= {AW{1'b0}};
                        state <= S_X;
                    end
                end

                S_X: begin
                    // rd_data is the sample at t0 + c - 1.
                    if (dv) x_ram[c[7:0] - 8'd1] <= enc8(rd_data);
                    x_addr <= c[7:0];
                    dv     <= 1'b1;
                    c      <= c + 1'b1;
                    if (c == POINTS) begin
                        c     <= {AW{1'b0}};
                        dv    <= 1'b0;
                        state <= S_Y;
                    end
                end

                S_Y: begin
                    if (dv) begin
                        wr_en   <= 1'b1;
                        wr_addr <= c[7:0] - 8'd1;
                        wr_x    <= x_q;              // x_ram[c-1]
                        wr_y    <= enc8(rd_data);
                    end
                    x_addr <= c[7:0];
                    dv     <= 1'b1;
                    c      <= c + 1'b1;
                    if (c == POINTS) begin
                        dv    <= 1'b0;
                        state <= S_FIN;
                    end
                end

                S_FIN: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
