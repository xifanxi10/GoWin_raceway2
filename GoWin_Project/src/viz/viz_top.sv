`timescale 1ns/1ps

// Visualisation co-processor board top (second Tang Primer 25K).
//
// Data path, all in the 50 MHz clock domain:
//
//   i2s_rx ---> sample_buf --+--> trigger_minmax --> wave_ram (256 x {min,max})
//   (96 kHz)    (2 x 2048)   |
//                            +--> fft2048 --> band_map --> spec_ram (64 x {bar,peak})
//                            |
//                            +--> xy_scope  --> xy_ram  (256 x {x,y})
//
//                                          frame_tx --> viz_tx (2 Mbps UART)
//
// One bank is analysed every 21.3 ms (2048 samples at 96 kHz); the analysis
// takes about 1.5 ms and the three drawing frames take 5.9 ms of UART time, so
// everything fits in the interval with plenty of margin.  Analysing every bank
// means WAVE/SPEC/XY leave at ~47 fps and STAT at ~11.7 fps; the MCU only takes
// the newest frame of each kind, so a higher rate than the 30 fps in the
// handover simply means the picture is never stale.
//
// The status pins are kept from the first milestone so the wiring can still be
// proven with three LEDs before the MCU is connected.
module viz_top #(
    parameter integer RESET_HOLD_CLKS = 500000,
    parameter integer BAUD            = 2_000_000
)(
    input  wire clk,
    input  wire reset_button,
    input  wire i2s_bclk,
    input  wire i2s_lrc,
    input  wire i2s_sd,
    output wire viz_tx,
    output wire status_alive,
    output wire status_align,
    output wire status_beat
);
    // ---- reset ------------------------------------------------------------
    (* syn_preserve=1, async_reg="true" *) reg button_meta = 1'b0;
    (* syn_preserve=1, async_reg="true" *) reg button_sync = 1'b0;
    localparam integer RESET_COUNT_WIDTH = $clog2(RESET_HOLD_CLKS + 1);
    reg [RESET_COUNT_WIDTH-1:0] reset_count = 0;
    wire core_reset_n = (reset_count == RESET_HOLD_CLKS);

    always @(posedge clk) begin
        button_meta <= reset_button;
        button_sync <= button_meta;
        if (button_sync)
            reset_count <= 0;
        else if (reset_count != RESET_HOLD_CLKS)
            reset_count <= reset_count + 1'b1;
    end

    // ---- I2S receiver ------------------------------------------------------
    wire signed [15:0] left, right;
    wire sample_stb, link_alive, align_error;
    wire [31:0] rx_frame_count;
    wire [15:0] pad_residue;

    i2s_rx u_rx (
        .clk         (clk),
        .reset_n     (core_reset_n),
        .bclk        (i2s_bclk),
        .lrc         (i2s_lrc),
        .sd          (i2s_sd),
        .left        (left),
        .right       (right),
        .sample_stb  (sample_stb),
        .link_alive  (link_alive),
        .align_error (align_error),
        .frame_count (rx_frame_count),
        .pad_residue (pad_residue)
    );

    // The audio board transmits identical L/R data; the left slot is the
    // reference channel for every analysis block.
    wire signed [15:0] mono = left;

    // ---- capture -----------------------------------------------------------
    // Set while an analysis pass owns the captured bank; sample_buf uses it to
    // defer a bank switch rather than overwrite samples being read.
    wire compute_busy;

    wire        blk_done, blk_bank;
    wire [31:0] blk_count, overrun_count;
    wire [10:0] samp_addr;
    wire signed [15:0] samp_data;
    reg         rd_bank;

    sample_buf u_buf (
        .clk           (clk),
        .reset_n       (core_reset_n),
        .sample_stb    (sample_stb),
        .sample        (mono),
        .blk_done      (blk_done),
        .blk_bank      (blk_bank),
        .blk_count     (blk_count),
        .overrun_count (overrun_count),
        .compute_busy  (compute_busy),
        .rd_bank       (rd_bank),
        .rd_addr       (samp_addr),
        .rd_data       (samp_data)
    );

    wire [7:0] peak_level, rms_level;
    wire       clipped;

    level_meter u_meter (
        .clk        (clk),
        .reset_n    (core_reset_n),
        .sample_stb (sample_stb),
        .sample     (mono),
        .blk_done   (blk_done),
        .peak_level (peak_level),
        .rms_level  (rms_level),
        .clipped    (clipped)
    );

    // ---- tables ------------------------------------------------------------
    wire        tables_ready;
    wire [10:0] hann_addr;
    wire [15:0] hann_val;
    wire [9:0]  tw_addr;
    wire signed [15:0] tw_cos, tw_sin;
    wire [31:0] table_init_cycles;

    viz_tables u_tables (
        .clk         (clk),
        .reset_n     (core_reset_n),
        .ready       (tables_ready),
        .hann_addr   (hann_addr),
        .hann_q15    (hann_val),
        .tw_addr     (tw_addr),
        .tw_cos      (tw_cos),
        .tw_sin      (tw_sin),
        .init_cycles (table_init_cycles)
    );

    // ---- analysis engines --------------------------------------------------
    reg  tm_start, fft_start, bm_start, xy_start, tx_start;

    wire        tm_busy, tm_done, tm_col_we;
    wire [10:0] tm_addr;
    wire [7:0]  tm_col_addr, tm_col_min, tm_col_max;
    wire [10:0] tm_trig;
    wire [15:0] tm_period, tm_cross;

    trigger_minmax u_wave (
        .clk         (clk),
        .reset_n     (core_reset_n),
        .start       (tm_start),
        .busy        (tm_busy),
        .done        (tm_done),
        .rd_addr     (tm_addr),
        .rd_data     (samp_data),
        .trig_index  (tm_trig),
        .period_est  (tm_period),
        .cross_count (tm_cross),
        .col_we      (tm_col_we),
        .col_addr    (tm_col_addr),
        .col_min     (tm_col_min),
        .col_max     (tm_col_max)
    );

    wire        fft_busy, fft_done, fft_ovf;
    wire [10:0] fft_smp_addr;
    wire [9:0]  fft_out_q;
    wire        fft_out_valid;
    wire [9:0]  fft_out_index;

    fft2048 u_fft (
        .clk       (clk),
        .reset_n   (core_reset_n),
        .start     (fft_start),
        .busy      (fft_busy),
        .done      (fft_done),
        .smp_addr  (fft_smp_addr),
        .smp_data  (samp_data),
        .hann_addr (hann_addr),
        .hann_val  (hann_val),
        .tw_addr   (tw_addr),
        .tw_cos    (tw_cos),
        .tw_sin    (tw_sin),
        .out_valid (fft_out_valid),
        .out_index (fft_out_index),
        .out_q     (fft_out_q),
        .overflow  (fft_ovf)
    );

    wire        bm_busy, bm_done, bm_wr_en;
    wire [5:0]  bm_wr_addr;
    wire [7:0]  bm_wr_bar, bm_wr_peak, bm_voice;
    wire [15:0] bm_frames;

    band_map u_bands (
        .clk         (clk),
        .reset_n     (core_reset_n),
        .start       (bm_start),
        .busy        (bm_busy),
        .done        (bm_done),
        .q_valid     (fft_out_valid),
        .q           (fft_out_q),
        .wr_en       (bm_wr_en),
        .wr_addr     (bm_wr_addr),
        .wr_bar      (bm_wr_bar),
        .wr_peak     (bm_wr_peak),
        .voice_est   (bm_voice),
        .frame_count (bm_frames)
    );

    wire        xy_busy, xy_done, xy_wr_en;
    wire [10:0] xy_addr;
    wire [7:0]  xy_wr_addr, xy_wr_x, xy_wr_y;

    xy_scope u_xy (
        .clk        (clk),
        .reset_n    (core_reset_n),
        .start      (xy_start),
        .trig_index (tm_trig),
        .period_est (tm_period),
        .busy       (xy_busy),
        .done       (xy_done),
        .rd_addr    (xy_addr),
        .rd_data    (samp_data),
        .wr_en      (xy_wr_en),
        .wr_addr    (xy_wr_addr),
        .wr_x       (xy_wr_x),
        .wr_y       (xy_wr_y)
    );

    // ---- payload buffers ---------------------------------------------------
    // One write port and one registered read port per buffer, so every one of
    // them maps to block RAM instead of ~9200 distributed registers.  The read
    // address is the frame transmitter's word counter; the word/target
    // selection happens after the registered read.
    reg [15:0] wave_ram [0:255];
    reg [15:0] xy_ram   [0:255];
    reg [15:0] stat_words [0:7];

    // SPEC: the payload is 64 bar bytes followed by 64 peak bytes, so word w
    // holds bands {2w, 2w+1} of the bar half for w < 32 and of the peak half
    // for w >= 32.  band_map emits one band per access, so the two halves of
    // each 16-bit word are paired here.
    reg [15:0] spec_bar_ram  [0:31];
    reg [15:0] spec_peak_ram [0:31];

    always @(posedge clk) if (tm_col_we) wave_ram[tm_col_addr] <= {tm_col_max, tm_col_min};
    always @(posedge clk) if (xy_wr_en)  xy_ram[xy_wr_addr]     <= {xy_wr_y, xy_wr_x};

    reg [7:0] prev_bar, prev_peak;
    always @(posedge clk) begin
        if (bm_wr_en) begin
            if (!bm_wr_addr[0]) begin
                prev_bar  <= bm_wr_bar;
                prev_peak <= bm_wr_peak;
            end else begin
                spec_bar_ram [bm_wr_addr[5:1]] <= {bm_wr_bar,  prev_bar};
                spec_peak_ram[bm_wr_addr[5:1]] <= {bm_wr_peak, prev_peak};
            end
        end
    end

    // STAT payload, byte 0..15 == word 0 low byte .. word 7 high byte.
    wire [7:0]  stat_flags = {5'd0, fft_ovf, link_alive, clipped};
    wire [15:0] key_mask   = 16'd0;          // no keyboard data reaches board B
    wire [7:0]  ratio_a    = 8'd1;           // quarter-period delay
    wire [7:0]  ratio_b    = 8'd4;

    always @(posedge clk) begin
        stat_words[0] <= {rms_level, peak_level};
        stat_words[1] <= {stat_flags, bm_voice};
        stat_words[2] <= key_mask;
        stat_words[3] <= {ratio_b, ratio_a};
        stat_words[4] <= rx_frame_count[15:0];
        stat_words[5] <= rx_frame_count[31:16];
        stat_words[6] <= bm_frames;
        stat_words[7] <= 16'd0;
    end

    // ---- frame transmitter -------------------------------------------------
    reg  [7:0] tx_type;
    wire       tx_busy, tx_done, tx_line;
    wire [8:0] tx_pay_addr;
    wire [31:0] tx_frames;
    reg  [15:0] pay_word;

    reg [15:0] wave_q, xy_q, spec_bar_q, spec_peak_q, stat_q;
    always @(posedge clk) begin
        wave_q      <= wave_ram[tx_pay_addr[7:0]];
        xy_q        <= xy_ram[tx_pay_addr[7:0]];
        spec_bar_q  <= spec_bar_ram[tx_pay_addr[4:0]];
        spec_peak_q <= spec_peak_ram[tx_pay_addr[4:0]];
        stat_q      <= stat_words[tx_pay_addr[2:0]];
    end

    always @(*) begin
        case (tx_type)
            8'h01:   pay_word = wave_q;
            8'h02:   pay_word = tx_pay_addr[5] ? spec_peak_q : spec_bar_q;
            8'h03:   pay_word = xy_q;
            default: pay_word = stat_q;
        endcase
    end
    frame_tx #(.CLK_HZ(50_000_000), .BAUD(BAUD)) u_tx (
        .clk         (clk),
        .rst_n       (core_reset_n),
        .start       (tx_start),
        .frame_type  (tx_type),
        .busy        (tx_busy),
        .done        (tx_done),
        .pay_addr    (tx_pay_addr),
        .pay_word    (pay_word),
        .tx          (tx_line),
        .frames_sent (tx_frames)
    );

    assign viz_tx = tx_line;

    // ---- sequencer ---------------------------------------------------------
    localparam [3:0] S_INIT = 4'd0, S_WAIT = 4'd1, S_WAVE = 4'd2, S_FFT = 4'd3,
                     S_XY = 4'd4, S_TX_W = 4'd5, S_TX_S = 4'd6, S_TX_X = 4'd7,
                     S_TX_ST = 4'd8;

    reg [3:0] state;
    reg       pending, pend_bank;
    reg [1:0] stat_div;
    // fft2048 and band_map run concurrently and finish on different clocks, so
    // their one-clock done pulses are latched instead of armed simultaneously.
    reg       fft_done_q, bm_done_q;
    assign compute_busy = (state == S_WAVE) || (state == S_FFT) || (state == S_XY);

    // sample_buf read port: the active engine owns it while it runs.
    assign samp_addr = (state == S_WAVE) ? tm_addr :
                       (state == S_FFT)  ? fft_smp_addr :
                       (state == S_XY)   ? xy_addr : 11'd0;

    always @(posedge clk or negedge core_reset_n) begin
        if (!core_reset_n) begin
            state      <= S_INIT;
            pending    <= 1'b0;
            pend_bank  <= 1'b0;
            stat_div   <= 2'd0;
            rd_bank    <= 1'b0;
            fft_done_q <= 1'b0;
            bm_done_q  <= 1'b0;
            tx_type    <= 8'h01;
            tm_start   <= 1'b0;
            fft_start  <= 1'b0;
            bm_start   <= 1'b0;
            xy_start   <= 1'b0;
            tx_start   <= 1'b0;
        end else begin
            tm_start  <= 1'b0;
            fft_start <= 1'b0;
            bm_start  <= 1'b0;
            xy_start  <= 1'b0;
            tx_start  <= 1'b0;

            if (blk_done) begin
                pending   <= 1'b1;
                pend_bank <= blk_bank;
            end
            if (fft_done) fft_done_q <= 1'b1;
            if (bm_done)  bm_done_q  <= 1'b1;

            case (state)
                S_INIT: if (tables_ready) state <= S_WAIT;

                S_WAIT: if (pending) begin
                    pending <= 1'b0;
                    rd_bank <= pend_bank;
                    tm_start <= 1'b1;
                    state <= S_WAVE;
                end

                S_WAVE: if (tm_done) begin
                    fft_start  <= 1'b1;
                    bm_start   <= 1'b1;
                    fft_done_q <= 1'b0;
                    bm_done_q  <= 1'b0;
                    state      <= S_FFT;
                end

                S_FFT: if (fft_done_q && bm_done_q) begin
                    xy_start   <= 1'b1;
                    fft_done_q <= 1'b0;
                    bm_done_q  <= 1'b0;
                    state      <= S_XY;
                end

                S_XY: if (xy_done) begin
                    tx_type  <= 8'h01;
                    tx_start <= 1'b1;
                    state    <= S_TX_W;
                end

                S_TX_W: if (tx_done) begin
                    tx_type  <= 8'h02;
                    tx_start <= 1'b1;
                    state    <= S_TX_S;
                end

                S_TX_S: if (tx_done) begin
                    tx_type  <= 8'h03;
                    tx_start <= 1'b1;
                    state    <= S_TX_X;
                end

                S_TX_X: if (tx_done) begin
                    if (stat_div == 2'd3) begin
                        stat_div <= 2'd0;
                        tx_type  <= 8'h04;
                        tx_start <= 1'b1;
                        state    <= S_TX_ST;
                    end else begin
                        stat_div <= stat_div + 2'd1;
                        state    <= S_WAIT;
                    end
                end

                S_TX_ST: if (tx_done) state <= S_WAIT;

                default: state <= S_WAIT;
            endcase
        end
    end

    // ---- status pins -------------------------------------------------------
    assign status_alive = link_alive;
    assign status_align = align_error;

    localparam integer BEAT_CLKS = 25000000;
    localparam integer BEAT_W = $clog2(BEAT_CLKS + 1);
    reg [BEAT_W-1:0] beat_count = 0;
    reg beat = 1'b0;
    always @(posedge clk) begin
        if (beat_count == BEAT_CLKS-1) begin
            beat_count <= 0;
            beat <= ~beat;
        end else begin
            beat_count <= beat_count + 1'b1;
        end
    end
    assign status_beat = beat;

    // Kept for waveform inspection; the synthesiser must not prune them.
    (* syn_keep=1 *) wire [31:0] dbg_blk    = blk_count;
    (* syn_keep=1 *) wire [31:0] dbg_over   = overrun_count;
    (* syn_keep=1 *) wire [31:0] dbg_init   = table_init_cycles;
    (* syn_keep=1 *) wire [31:0] dbg_frames = tx_frames;
    (* syn_keep=1 *) wire [31:0] dbg_pad    = {16'd0, pad_residue};
    (* syn_keep=1 *) wire [15:0] dbg_rtap   = right;
endmodule
