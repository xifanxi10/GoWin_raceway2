`timescale 1ns/1ps

// Ping-pong capture buffer for the visualiser.
//
// 96 kHz samples are written into one 2048-deep bank; when the bank fills, the
// completed bank is handed to the analysis engine and capture continues in the
// other bank.  One bank holds 21.3 ms of audio, several times longer than the
// whole analysis pass, so capture never stalls in practice.  If an analysis did
// overrun, capture is held at the bank boundary and the lost samples are
// counted instead of corrupting the bank being read.
module sample_buf #(
    parameter integer DEPTH = 2048,
    parameter integer AW    = 11
)(
    input  wire               clk,
    input  wire               reset_n,
    input  wire               sample_stb,
    input  wire signed [15:0] sample,
    output reg                blk_done,      // one-clock pulse, bank complete
    output reg                blk_bank,      // bank that just completed
    output reg  [31:0]        blk_count,
    output reg  [31:0]        overrun_count,
    input  wire               compute_busy,  // analysis is reading a bank
    input  wire               rd_bank,
    input  wire [AW-1:0]      rd_addr,
    output reg  signed [15:0] rd_data
);
    reg signed [15:0] mem0 [0:DEPTH-1];
    reg signed [15:0] mem1 [0:DEPTH-1];

    reg               wr_bank;
    reg               stalled;
    reg [AW-1:0]      wr_addr;

    wire wr_en   = sample_stb && !stalled;
    wire blk_end = wr_en && (wr_addr == DEPTH-1);

    // The bank capture is about to switch into may still be owned by the
    // analysis engine; then the switch waits for it.
    wire switch_blocked = compute_busy && (rd_bank == ~wr_bank);
    wire can_switch     = !switch_blocked;

    always @(posedge clk) begin
        if (wr_en && !wr_bank) mem0[wr_addr] <= sample;
    end
    always @(posedge clk) begin
        if (wr_en && wr_bank) mem1[wr_addr] <= sample;
    end
    always @(posedge clk) begin
        rd_data <= rd_bank ? mem1[rd_addr] : mem0[rd_addr];
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wr_bank       <= 1'b0;
            wr_addr       <= {AW{1'b0}};
            stalled       <= 1'b0;
            blk_done      <= 1'b0;
            blk_bank      <= 1'b0;
            blk_count     <= 32'd0;
            overrun_count <= 32'd0;
        end else begin
            blk_done <= 1'b0;
            if (stalled) begin
                if (sample_stb) overrun_count <= overrun_count + 32'd1;
                if (can_switch) begin
                    stalled <= 1'b0;
                    wr_bank <= ~wr_bank;
                    wr_addr <= {AW{1'b0}};
                end
            end else if (blk_end) begin
                blk_done  <= 1'b1;
                blk_bank  <= wr_bank;
                blk_count <= blk_count + 32'd1;
                if (can_switch) begin
                    wr_bank <= ~wr_bank;
                    wr_addr <= {AW{1'b0}};
                end else begin
                    stalled <= 1'b1;
                end
            end else if (wr_en) begin
                wr_addr <= wr_addr + 1'b1;
            end
        end
    end
endmodule

// Peak / RMS meter and clip detector, evaluated once per captured bank.
// Published values are 8-bit LSB-aligned levels (0..255), as the STAT frame
// expects.  The square root runs after the bank ends and never blocks capture.
module level_meter #(
    parameter integer DEPTH = 2048,
    parameter integer SW    = 11           // $clog2(DEPTH)
)(
    input  wire               clk,
    input  wire               reset_n,
    input  wire               sample_stb,
    input  wire signed [15:0] sample,
    input  wire               blk_done,
    output reg  [7:0]         peak_level,
    output reg  [7:0]         rms_level,
    output reg                clipped
);
    wire [15:0] mag_w = sample[15] ? (~sample + 16'd1) : sample;
    wire [31:0] sq_w  = sample * sample;

    reg [15:0] peak_acc;
    reg [47:0] sumsq;
    reg [15:0] peak_cap;
    reg [31:0] msq;
    // Rounded mean square of the finished bank.
    wire [47:0] mean_w = (sumsq + (48'd1 << (SW-1))) >> SW;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            peak_acc <= 16'd0;
            sumsq    <= 48'd0;
            peak_cap <= 16'd0;
            msq      <= 32'd0;
        end else begin
            if (sample_stb) begin
                if (mag_w > peak_acc) peak_acc <= mag_w;
                sumsq <= sumsq + {16'd0, sq_w};
            end
            if (blk_done) begin
                peak_cap <= (mag_w > peak_acc) ? mag_w : peak_acc;
                msq      <= mean_w[31:0];
                peak_acc <= 16'd0;
                sumsq    <= 48'd0;
            end
        end
    end

    // Restoring square root of the mean square: 16 steps, one per clock, then
    // one more clock to publish the final root.
    reg [4:0]  sstep;
    reg        sqrt_busy;
    reg        sqrt_pub;
    reg [31:0] rem;
    reg [17:0] root;

    wire [31:0] rem_sh = {rem[29:0], 2'b00} |
                         {30'd0, (msq >> {sstep[3:0], 1'b0}) & 32'd3};
    wire [31:0] cand32 = {12'd0, root, 2'b01};
    wire        take   = rem_sh >= cand32;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sqrt_busy  <= 1'b0;
            sqrt_pub   <= 1'b0;
            sstep      <= 5'd15;
            rem        <= 32'd0;
            root       <= 18'd0;
            rms_level  <= 8'd0;
            peak_level <= 8'd0;
            clipped    <= 1'b0;
        end else if (blk_done) begin
            sqrt_busy <= 1'b1;
            sqrt_pub  <= 1'b0;
            sstep     <= 5'd15;
            rem       <= 32'd0;
            root      <= 18'd0;
        end else if (sqrt_busy) begin
            if (take) begin
                rem  <= rem_sh - cand32;
                root <= {root[16:0], 1'b1};
            end else begin
                rem  <= rem_sh;
                root <= {root[16:0], 1'b0};
            end
            if (sstep == 5'd0) begin
                sqrt_busy <= 1'b0;
                sqrt_pub  <= 1'b1;
            end else begin
                sstep <= sstep - 5'd1;
            end
        end else if (sqrt_pub) begin
            sqrt_pub   <= 1'b0;
            rms_level  <= (|root[17:15]) ? 8'd255 : root[14:7];
            peak_level <= (peak_cap[15]) ? 8'd255 : peak_cap[14:7];
            clipped    <= (peak_cap >= 16'd32767);
        end
    end
endmodule
