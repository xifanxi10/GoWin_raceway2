`timescale 1ns/1ps

// Log-frequency band mapper with peak hold.
//
// The FFT streams 1024 log-domain bin magnitudes (q = 16*log2(|X|^2)) in
// ascending bin order; they are buffered here and then reduced band by band
// because the 64 bands are not one bin each: below ~215 Hz a band is narrower
// than the 46.9 Hz bin spacing, and at the top a band spans up to 29 bins.
//
// dB mapping: q -> 8-bit bar with v = min(255, 137*q/256).  That is the
// documented (20*log10(mag) + 90) * 255/90 law evaluated with the reference
// point |X| = 2^15 == 0 dB, which the FFT scaling guarantees for a full-scale
// sine; v = 0 means "90 dB below full scale or quieter".
//
// Peak hold decays by DECAY counts per frame so a transient stays visible for a
// few hundred milliseconds at 30-45 frames per second.
module band_map #(
    parameter integer NBANDS    = 64,
    parameter integer NBINS     = 1024,
    parameter integer DECAY     = 1,
    parameter integer VOICE_MIN = 64        // ~ -50 dBFS
)(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        start,
    output reg         busy,
    output reg         done,
    input  wire        q_valid,
    input  wire [9:0]  q,
    output reg         wr_en,
    output reg  [5:0]  wr_addr,
    output reg  [7:0]  wr_bar,
    output reg  [7:0]  wr_peak,
    output reg  [7:0]  voice_est,
    output reg  [15:0] frame_count
);
    // Band edges in FFT bins: 64 bands of 1/64 octave spanning 50 Hz..16 kHz
    // (46.875 Hz per bin at 96 kHz / 2048).
    function automatic [9:0] band_edge(input [5:0] b);
        case (b)
            6'd0:  band_edge = 10'd1;     6'd1:  band_edge = 10'd1;
            6'd2:  band_edge = 10'd1;     6'd3:  band_edge = 10'd1;
            6'd4:  band_edge = 10'd2;     6'd5:  band_edge = 10'd2;
            6'd6:  band_edge = 10'd2;     6'd7:  band_edge = 10'd2;
            6'd8:  band_edge = 10'd2;     6'd9:  band_edge = 10'd2;
            6'd10: band_edge = 10'd3;     6'd11: band_edge = 10'd3;
            6'd12: band_edge = 10'd3;     6'd13: band_edge = 10'd3;
            6'd14: band_edge = 10'd4;     6'd15: band_edge = 10'd4;
            6'd16: band_edge = 10'd5;     6'd17: band_edge = 10'd5;
            6'd18: band_edge = 10'd5;     6'd19: band_edge = 10'd6;
            6'd20: band_edge = 10'd6;     6'd21: band_edge = 10'd7;
            6'd22: band_edge = 10'd8;     6'd23: band_edge = 10'd8;
            6'd24: band_edge = 10'd9;     6'd25: band_edge = 10'd10;
            6'd26: band_edge = 10'd11;    6'd27: band_edge = 10'd12;
            6'd28: band_edge = 10'd13;    6'd29: band_edge = 10'd15;
            6'd30: band_edge = 10'd16;    6'd31: band_edge = 10'd17;
            6'd32: band_edge = 10'd19;    6'd33: band_edge = 10'd21;
            6'd34: band_edge = 10'd23;    6'd35: band_edge = 10'd25;
            6'd36: band_edge = 10'd27;    6'd37: band_edge = 10'd30;
            6'd38: band_edge = 10'd33;    6'd39: band_edge = 10'd36;
            6'd40: band_edge = 10'd39;    6'd41: band_edge = 10'd43;
            6'd42: band_edge = 10'd47;    6'd43: band_edge = 10'd51;
            6'd44: band_edge = 10'd56;    6'd45: band_edge = 10'd62;
            6'd46: band_edge = 10'd67;    6'd47: band_edge = 10'd74;
            6'd48: band_edge = 10'd81;    6'd49: band_edge = 10'd88;
            6'd50: band_edge = 10'd97;    6'd51: band_edge = 10'd106;
            6'd52: band_edge = 10'd116;   6'd53: band_edge = 10'd127;
            6'd54: band_edge = 10'd139;   6'd55: band_edge = 10'd152;
            6'd56: band_edge = 10'd166;   6'd57: band_edge = 10'd182;
            6'd58: band_edge = 10'd199;   6'd59: band_edge = 10'd218;
            6'd60: band_edge = 10'd238;   6'd61: band_edge = 10'd260;
            6'd62: band_edge = 10'd285;   6'd63: band_edge = 10'd312;
            default: band_edge = 10'd341;  // band 64: 16 kHz
        endcase
    endfunction

    function automatic [7:0] db8(input [9:0] qv);
        reg [17:0] t;
        begin
            t   = {8'd0, qv} * 18'd137;
            t   = t >> 8;
            db8 = (t > 18'd255) ? 8'd255 : t[7:0];
        end
    endfunction

    localparam [2:0] S_IDLE = 3'd0, S_CAP = 3'd1, S_INIT = 3'd2,
                     S_READ = 3'd3, S_ACC = 3'd4, S_EMIT = 3'd5,
                     S_NEXT = 3'd6, S_FIN = 3'd7;

    reg [2:0]  state;
    reg [9:0]  q_cnt;
    reg [9:0]  q_addr;
    reg [9:0]  q_data;
    reg [9:0] q_ram [0:NBINS-1];

    reg [5:0]  band;
    reg [9:0]  k, k_end, qmax;
    reg [7:0]  peak_reg [0:NBANDS-1];
    reg [7:0]  bar_prev, bar_prev2;
    reg [3:0]  voices;
    integer    pi;

    wire [9:0] edge_next = band_edge(band + 6'd1);
    wire [9:0] band_max  = (q_data > qmax) ? q_data : qmax;
    // The emitted bar depends only on the latched band maximum, never on the
    // block-RAM output, so the dB multiply and peak compare stay off that path.
    wire [7:0] bar_now   = db8(qmax);

    always @(posedge clk) begin
        if (state == S_CAP && q_valid) q_ram[q_cnt] <= q;
        q_data <= q_ram[q_addr];
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            q_cnt       <= 10'd0;
            q_addr      <= 10'd0;
            band        <= 6'd0;
            k           <= 10'd0;
            k_end       <= 10'd0;
            qmax        <= 10'd0;
            bar_prev    <= 8'd0;
            bar_prev2   <= 8'd0;
            voices      <= 4'd0;
            wr_en       <= 1'b0;
            wr_addr     <= 6'd0;
            wr_bar      <= 8'd0;
            wr_peak     <= 8'd0;
            voice_est   <= 8'd0;
            frame_count <= 16'd0;
            for (pi = 0; pi < NBANDS; pi = pi + 1) peak_reg[pi] <= 8'd0;
        end else begin
            wr_en <= 1'b0;
            done  <= 1'b0;
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy      <= 1'b1;
                        q_cnt     <= 10'd0;
                        voices    <= 4'd0;
                        bar_prev  <= 8'd0;
                        bar_prev2 <= 8'd0;
                        state     <= S_CAP;
                    end
                end

                S_CAP: begin
                    if (q_valid) begin
                        q_cnt <= q_cnt + 10'd1;
                        if (q_cnt == NBINS - 1) begin
                            band  <= 6'd0;
                            k     <= band_edge(6'd0);
                            k_end <= (band_edge(6'd1) <= band_edge(6'd0)) ?
                                     band_edge(6'd0) + 10'd1 : band_edge(6'd1);
                            qmax  <= 10'd0;
                            q_addr <= band_edge(6'd0);
                            state <= S_INIT;
                        end
                    end
                end

                S_INIT: state <= S_READ;
                S_READ: state <= S_ACC;

                S_ACC: begin
                    if (band_max > qmax) qmax <= band_max;
                    if (k + 10'd1 < k_end) begin
                        k      <= k + 10'd1;
                        q_addr <= k + 10'd1;
                        state  <= S_READ;
                    end else begin
                        // Latch the band maximum, then close the band in the
                        // next cycle: that keeps the dB multiply and the peak
                        // compare off the block-RAM output path.
                        qmax  <= band_max;
                        state <= S_EMIT;
                    end
                end

                S_EMIT: begin
                    wr_en          <= 1'b1;
                    wr_addr        <= band;
                    wr_bar         <= bar_now;
                    wr_peak        <= (bar_now >= peak_reg[band]) ? bar_now :
                                      ((peak_reg[band] > DECAY) ? peak_reg[band] - DECAY : 8'd0);
                    peak_reg[band] <= (bar_now >= peak_reg[band]) ? bar_now :
                                      ((peak_reg[band] > DECAY) ? peak_reg[band] - DECAY : 8'd0);
                    // Local maxima across bands estimate the active voices.
                    if (band >= 6'd2 &&
                        bar_prev > bar_prev2 && bar_prev >= bar_now &&
                        bar_prev > VOICE_MIN && voices != 4'd12)
                        voices <= voices + 4'd1;
                    bar_prev2 <= bar_prev;
                    bar_prev  <= bar_now;
                    qmax      <= 10'd0;
                    state     <= S_NEXT;
                end

                S_NEXT: begin
                    if (band == NBANDS - 1) begin
                        voice_est   <= {4'd0, voices};
                        frame_count <= frame_count + 16'd1;
                        state       <= S_FIN;
                    end else begin
                        band    <= band + 6'd1;
                        k       <= edge_next;
                        k_end   <= (band_edge(band + 6'd2) <= edge_next) ?
                                   edge_next + 10'd1 : band_edge(band + 6'd2);
                        q_addr  <= edge_next;
                        state   <= S_READ;
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
