`timescale 1ns/1ps

// 2048-point real FFT, radix-2 decimation in time, one butterfly at a time.
//
// Input stage: the captured 2048-sample bank is read in natural order, windowed
// with the on-chip Hann table and written into the butterfly memory at
// bit-reversed addresses (DIT wants bit-reversed input, and doing the reversal
// on the write side leaves the read side sequential).
//
// Butterfly stage: 11 stages, 1024 butterflies each, six clocks per butterfly
// (read x0, read x1 + twiddle, latch, twiddle-multiply, write x0', write x1').
// The memory is updated in place: a butterfly only ever touches its own two
// addresses and stages run to completion, so no second buffer is needed.
//
// Scaling: the input is pre-scaled by 4 (window Q15 divided by 2^13 instead of
// 2^15) and every butterfly shifts right by one, so an 18-bit datapath can
// never overflow and a full-scale sine still lands at 2^15 of output magnitude,
// which is exactly the 8-bit dB reference used by band_map.
//
// Output stage: 1024 positive-frequency bins, converted to a 16*log2(|X|^2)
// value (q) so that the band mapper needs no square root and no divider.
module fft2048 (
    input  wire               clk,
    input  wire               reset_n,
    input  wire               start,
    output reg                busy,
    output reg                done,
    output wire [10:0]        smp_addr,
    input  wire signed [15:0] smp_data,
    output wire [10:0]        hann_addr,
    input  wire [15:0]        hann_val,
    output wire [9:0]         tw_addr,
    input  wire signed [15:0] tw_cos,
    input  wire signed [15:0] tw_sin,
    output reg                out_valid,
    output reg  [9:0]         out_index,
    output reg  [9:0]         out_q,
    output reg                overflow
);
    localparam integer N     = 2048;
    localparam integer NBINS = 1024;
    localparam integer NSTG  = 11;

    localparam [2:0] S_IDLE  = 3'd0, S_LOAD = 3'd1, S_STAGE = 3'd2,
                     S_OUT   = 3'd3, S_FIN  = 3'd4;

    reg [35:0] mem [0:N-1];          // {I[17:0], Q[17:0]}
    reg [2:0]  state;

    // ---- datapath registers ----------------------------------------------
    reg [11:0] ld_cnt;               // input sample counter
    reg [17:0] ld_prod;
    reg [10:0] ld_waddr;
    reg        ld_wen;
    reg [3:0]  st_p;                 // stage index 0..10
    reg [9:0]  bf;                   // butterfly index 0..1023
    reg [2:0]  ph;                   // phase inside a butterfly
    reg signed [17:0] x0_i, x0_q;
    reg signed [17:0] x1_i, x1_q;
    reg signed [15:0] twc, tws;
    reg signed [18:0] v_re, v_im;
    reg [11:0] o_cnt;
    reg [35:0] msq;
    reg [9:0]  o_idx;
    reg        o_msq_valid;
    reg [35:0] rd_q;

    // ---- memory ports ------------------------------------------------------
    wire [10:0] bf_half = 11'd1 << st_p[3:0];
    wire [10:0] bf11    = {1'b0, bf};
    wire [10:0] bf_j    = bf11 & (bf_half - 11'd1);
    wire [10:0] bf_a0   = (((bf11 >> st_p[3:0]) << (st_p[3:0] + 4'd1)) | bf_j);
    wire [10:0] bf_a1   = bf_a0 + bf_half;
    wire [9:0]  bf_ti   = bf_j[9:0] << (4'd10 - st_p[3:0]);

    wire [10:0] bf_raddr  = (ph == 3'd0) ? bf_a0 :
                            (ph == 3'd1) ? bf_a1 : 11'd0;
    wire [10:0] mem_raddr = (state == S_STAGE) ? bf_raddr : o_cnt[10:0];

    assign smp_addr  = ld_cnt[10:0];
    assign hann_addr = ld_cnt[10:0];
    assign tw_addr   = bf_ti;

    function automatic signed [17:0] sat18(input signed [19:0] v);
        begin
            if (v > 20'sd131071) sat18 = 18'sh1ffff;
            else if (v < -20'sd131072) sat18 = 18'sh20000;
            else sat18 = v[17:0];
        end
    endfunction

    // Butterfly outputs, written straight into the RAM (phase 4 and 5).
    wire signed [19:0] sum0_i = {{2{x0_i[17]}}, x0_i} + {{1{v_re[18]}}, v_re};
    wire signed [19:0] sum0_q = {{2{x0_q[17]}}, x0_q} + {{1{v_im[18]}}, v_im};
    wire signed [19:0] sum1_i = {{2{x0_i[17]}}, x0_i} - {{1{v_re[18]}}, v_re};
    wire signed [19:0] sum1_q = {{2{x0_q[17]}}, x0_q} - {{1{v_im[18]}}, v_im};

    wire signed [19:0] o0_i = sum0_i >>> 1;
    wire signed [19:0] o0_q = sum0_q >>> 1;
    wire signed [19:0] o1_i = sum1_i >>> 1;
    wire signed [19:0] o1_q = sum1_q >>> 1;

    wire ovf0 = (o0_i > 20'sd131071) || (o0_i < -20'sd131072) ||
                (o0_q > 20'sd131071) || (o0_q < -20'sd131072) ||
                (o1_i > 20'sd131071) || (o1_i < -20'sd131072) ||
                (o1_q > 20'sd131071) || (o1_q < -20'sd131072);

    // Twiddle multiply of the second half, rounded back to Q15 domain.
    wire signed [37:0] pre_re = ($signed(x1_i) * $signed(twc)) - ($signed(x1_q) * $signed(tws));
    wire signed [37:0] pre_im = ($signed(x1_i) * $signed(tws)) + ($signed(x1_q) * $signed(twc));

    // Window multiply.  The product must be formed in a wide context: Verilog
    // sizes a multiply to max(operand width), not to the sum, so assigning
    // straight into an 18-bit register would drop the product's top bits.
    wire signed [32:0] ld_mul = $signed(smp_data) * $signed({1'b0, hann_val});

    // Signed view of the bin being squared (a bare part-select is unsigned).
    wire signed [17:0] bin_i = rd_q[35:18];
    wire signed [17:0] bin_q = rd_q[17:0];

    // 16*log2(|X|^2): MSB position plus the next four bits, 0.35 dB resolution.
    function automatic [9:0] log2q(input [35:0] v);
        integer i;
        reg found;
        reg [5:0] p;
        reg [35:0] w;
        begin
            p = 6'd0;
            found = 1'b0;
            for (i = 35; i >= 0; i = i - 1) begin
                if (!found && v[i]) begin
                    p = i;
                    found = 1'b1;
                end
            end
            w = v << (6'd35 - p);
            log2q = ({4'd0, p} << 4) + w[34:31];
        end
    endfunction

    function automatic [10:0] bitrev11(input [10:0] v);
        begin
            bitrev11 = {v[0], v[1], v[2], v[3], v[4], v[5],
                        v[6], v[7], v[8], v[9], v[10]};
        end
    endfunction

    // ---- butterfly memory: exactly one read and one write port -------------
    // Gowin can only infer block RAM for a single write port, so the three
    // producers (window load, phase 4, phase 5) are multiplexed into one.
    reg [10:0] mem_waddr;
    reg [35:0] mem_wdata;
    reg        mem_wen;

    always @(posedge clk) begin
        if (ld_wen) begin
            mem_wen   <= 1'b1;
            mem_waddr <= ld_waddr;
            mem_wdata <= {ld_prod, 18'd0};
        end else if (state == S_STAGE && ph == 3'd4) begin
            mem_wen   <= 1'b1;
            mem_waddr <= bf_a0;
            mem_wdata <= {sat18(o0_i), sat18(o0_q)};
        end else if (state == S_STAGE && ph == 3'd5) begin
            mem_wen   <= 1'b1;
            mem_waddr <= bf_a1;
            mem_wdata <= {sat18(o1_i), sat18(o1_q)};
        end else begin
            mem_wen   <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (mem_wen) mem[mem_waddr] <= mem_wdata;
        rd_q <= mem[mem_raddr];
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            ld_cnt      <= 12'd0;
            ld_prod     <= 18'd0;
            ld_waddr    <= 11'd0;
            ld_wen      <= 1'b0;
            st_p        <= 4'd0;
            bf          <= 10'd0;
            ph          <= 3'd0;
            x0_i        <= 18'sd0;
            x0_q        <= 18'sd0;
            x1_i        <= 18'sd0;
            x1_q        <= 18'sd0;
            twc         <= 16'sd0;
            tws         <= 16'sd0;
            v_re        <= 19'sd0;
            v_im        <= 19'sd0;
            o_cnt       <= 12'd0;
            msq         <= 36'd0;
            o_idx       <= 10'd0;
            o_msq_valid <= 1'b0;
            out_valid   <= 1'b0;
            out_index   <= 10'd0;
            out_q       <= 10'd0;
            overflow    <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            done      <= 1'b0;
            ld_wen    <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy     <= 1'b1;
                        ld_cnt   <= 12'd0;
                        st_p     <= 4'd0;
                        bf       <= 10'd0;
                        ph       <= 3'd0;
                        o_cnt    <= 12'd0;
                        o_msq_valid <= 1'b0;
                        overflow <= 1'b0;
                        state    <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    // rd_q holds the sample for ld_cnt-1; the window table is
                    // read with the same index and arrives together.
                    if (ld_cnt != 12'd0 && ld_cnt <= N) begin
                        ld_prod  <= (ld_mul + 33'sd4096) >>> 13;
                        ld_waddr <= bitrev11(ld_cnt[10:0] - 11'd1);
                        ld_wen   <= 1'b1;
                    end
                    ld_cnt <= ld_cnt + 12'd1;
                    if (ld_cnt == N + 3) begin
                        ld_cnt <= 12'd0;
                        state  <= S_STAGE;
                    end
                end

                S_STAGE: begin
                    ph <= ph + 3'd1;
                    case (ph)
                        3'd0: ;                                   // read x0
                        3'd1: begin                               // read x1 + twiddle
                            x0_i <= rd_q[35:18];
                            x0_q <= rd_q[17:0];
                        end
                        3'd2: begin
                            x1_i <= rd_q[35:18];
                            x1_q <= rd_q[17:0];
                            twc  <= tw_cos;
                            tws  <= tw_sin;
                        end
                        3'd3: begin
                            v_re <= (pre_re + 38'sd16384) >>> 15;
                            v_im <= (pre_im + 38'sd16384) >>> 15;
                        end
                        3'd4: if (ovf0) overflow <= 1'b1;
                        3'd5: begin
                            ph <= 3'd0;
                            if (bf == NBINS - 1) begin
                                bf <= 10'd0;
                                if (st_p == NSTG - 1) state <= S_OUT;
                                else st_p <= st_p + 4'd1;
                            end else begin
                                bf <= bf + 10'd1;
                            end
                        end
                        default: ;
                    endcase
                end

                S_OUT: begin
                    o_cnt <= o_cnt + 12'd1;
                    // Stage A: rd_q holds the bin addressed in the last cycle.
                    if (o_cnt != 12'd0) begin
                        msq   <= (bin_i * bin_i) + (bin_q * bin_q);
                        o_idx <= o_cnt[9:0] - 10'd1;
                    end
                    // Stage B: msq holds the bin in o_idx.
                    if (o_msq_valid && o_cnt <= NBINS + 1) begin
                        out_q     <= log2q(msq);
                        out_index <= o_idx;
                        out_valid <= 1'b1;
                    end
                    o_msq_valid <= (o_cnt != 12'd0);
                    if (o_cnt == NBINS + 3) state <= S_FIN;
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
