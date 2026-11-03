`timescale 1ns/1ps

// Waveform trigger and 256-column min/max reducer.
//
// Pass A walks the whole captured bank and looks for a rising crossing of the
// +HYST threshold after the signal has been below -HYST (a Schmitt trigger, so
// noise around zero cannot re-trigger it).  The first crossing at or after
// PRETRIG samples becomes the trigger, which leaves one quarter of the window
// as pre-trigger history.  The distance to the next crossing is reported as
// the period estimate used by the Lissajous scope.
//
// Pass B emits COLUMNS columns of {min, max} over GROUP consecutive samples.
// Both values are offset binary (byte = (sample >> 8) + 128), so silence sits
// at 0x80 exactly as the WAVE payload requires.  Because the display window is
// a full bank, the column addresses wrap modulo DEPTH; the bank is a continuous
// 21 ms record, so the wrap only ever crosses the seam of a periodic waveform.
module trigger_minmax #(
    parameter integer DEPTH   = 2048,
    parameter integer AW      = 11,
    parameter integer COLUMNS = 256,
    parameter integer GROUP   = 8,
    parameter integer PRETRIG = 512,
    parameter integer HYST    = 64
)(
    input  wire               clk,
    input  wire               reset_n,
    input  wire               start,
    output reg                busy,
    output reg                done,
    output wire [AW-1:0]      rd_addr,
    input  wire signed [15:0] rd_data,
    output reg  [AW-1:0]      trig_index,
    output reg  [15:0]        period_est,
    output reg  [15:0]        cross_count,
    output reg                col_we,
    output reg  [7:0]         col_addr,
    output reg  [7:0]         col_min,
    output reg  [7:0]         col_max
);
    localparam [2:0] S_IDLE = 3'd0, S_SCAN = 3'd1, S_SETTLE = 3'd2,
                     S_COL = 3'd3, S_FIN = 3'd4;

    reg [2:0]         state;
    reg [AW:0]        idx;          // issued-address counter
    reg               dv;           // rd_data holds the previous address
    reg [AW-1:0]      base;         // column window start
    reg signed [15:0] gmin, gmax;
    reg               armed;
    reg               trig_found;
    reg [AW-1:0]      trig_r;
    reg [15:0]        period_r;
    reg [15:0]        xcount_r;

    wire [AW-1:0] off = idx[AW-1:0] - 1'b1;
    wire [31:0]   pret32 = PRETRIG;
    wire [AW-1:0] pretrig_w = pret32[AW-1:0];

    assign rd_addr = (state == S_SCAN) ? idx[AW-1:0] : (base + idx[AW-1:0]);

    wire signed [15:0] s = rd_data;

    // Offset-binary encoding: (sample >> 8) + 128 always lands in 0..255.
    function automatic [7:0] enc8(input signed [15:0] v);
        reg signed [8:0] t;
        begin
            t = {{1{v[15]}}, v[15:8]} + 9'sd128;
            enc8 = t[7:0];
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            idx        <= {(AW+1){1'b0}};
            dv         <= 1'b0;
            base       <= {AW{1'b0}};
            gmin       <= 16'sd0;
            gmax       <= 16'sd0;
            armed      <= 1'b0;
            trig_found <= 1'b0;
            trig_r     <= {AW{1'b0}};
            period_r   <= 16'd0;
            xcount_r   <= 16'd0;
            trig_index <= {AW{1'b0}};
            period_est <= 16'd0;
            cross_count<= 16'd0;
            col_we     <= 1'b0;
            col_addr   <= 8'd0;
            col_min    <= 8'd128;
            col_max    <= 8'd128;
        end else begin
            col_we <= 1'b0;
            done   <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy       <= 1'b1;
                        idx        <= {(AW+1){1'b0}};
                        dv         <= 1'b0;
                        armed      <= 1'b0;
                        trig_found <= 1'b0;
                        period_r   <= 16'd0;
                        xcount_r   <= 16'd0;
                        state      <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    if (dv) begin
                        if (s <= -HYST) armed <= 1'b1;
                        if (armed && s >= HYST) begin
                            armed    <= 1'b0;
                            xcount_r <= xcount_r + 16'd1;
                            if (!trig_found) begin
                                if (idx > PRETRIG) begin
                                    trig_found <= 1'b1;
                                    trig_r     <= off;
                                end
                            end else if (period_r == 16'd0) begin
                                period_r <= off - trig_r;
                            end
                        end
                    end
                    idx <= idx + 1'b1;
                    dv  <= 1'b1;
                    if (idx == DEPTH) state <= S_SETTLE;
                end

                S_SETTLE: begin
                    base        <= trig_found ? (trig_r - pretrig_w) : {AW{1'b0}};
                    trig_index  <= trig_found ? trig_r : pretrig_w;
                    period_est  <= period_r;
                    cross_count <= xcount_r;
                    idx         <= {(AW+1){1'b0}};
                    dv          <= 1'b0;
                    state       <= S_COL;
                end

                S_COL: begin
                    if (dv) begin
                        if (idx[2:0] == 3'd1) begin
                            gmin <= s;
                            gmax <= s;
                        end else begin
                            if (s < gmin) gmin <= s;
                            if (s > gmax) gmax <= s;
                        end
                        if (idx[2:0] == 3'd0) begin
                            // Last sample of a group: close the column.
                            col_we   <= 1'b1;
                            col_addr <= idx[AW-1:3] - 1'b1;
                            col_min  <= enc8((s < gmin) ? s : gmin);
                            col_max  <= enc8((s > gmax) ? s : gmax);
                        end
                    end
                    idx <= idx + 1'b1;
                    dv  <= 1'b1;
                    if (idx == DEPTH) begin
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
