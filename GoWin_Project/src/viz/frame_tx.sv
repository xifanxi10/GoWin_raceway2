`timescale 1ns/1ps

// Frame transmitter: AA 7C | type | seq | payload | CRC16 (low byte first).
//
// The payload is read as 16-bit words from whichever buffer the caller selects
// (the word count follows the frame type: WAVE/XY 256 words, SPEC 64, STAT 8).
// Each word leaves low byte first, which is exactly the byte order the protocol
// wants for {min,max}, {bar,peak}, {x,y} and the little-endian STAT fields.
//
// CRC16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection) covers
// type..payload-end: every byte except the two-byte header and the CRC itself.
//
// A byte is accepted whenever link_uart_tx says ready, so the 2 Mbps line rate
// paces the whole state machine and no FIFO is needed.
module frame_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 2_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [7:0]  frame_type,
    output reg         busy,
    output reg         done,
    output reg  [8:0]  pay_addr,
    input  wire [15:0] pay_word,
    output reg         tx,
    output reg  [31:0] frames_sent
);
    localparam [3:0] S_IDLE  = 4'd0, S_HDR0 = 4'd1, S_HDR1 = 4'd2, S_TYPE = 4'd3,
                     S_SEQ   = 4'd4, S_WLOAD = 4'd5, S_WLOW = 4'd6, S_WHIGH = 4'd7,
                     S_CRC0  = 4'd8, S_CRC1 = 4'd9, S_DONE = 4'd10;

    reg [3:0]  state;
    reg [7:0]  type_r;
    reg [7:0]  seq_r;
    reg [7:0]  seq_ctr [0:3];
    reg [8:0]  w;
    reg [8:0]  n_words;
    reg [15:0] word_r;
    reg [15:0] crc;
    reg [1:0]  wload_cnt;
    reg        tx_valid;
    reg [7:0]  tx_byte;
    integer    si;

    wire tx_ready;

    // Byte source and valid flag for the current state.
    always @(*) begin
        case (state)
            S_HDR0:  tx_byte = 8'hAA;
            S_HDR1:  tx_byte = 8'h7C;
            S_TYPE:  tx_byte = type_r;
            S_SEQ:   tx_byte = seq_r;
            S_WLOW:  tx_byte = word_r[7:0];
            S_WHIGH: tx_byte = word_r[15:8];
            S_CRC0:  tx_byte = crc[7:0];
            S_CRC1:  tx_byte = crc[15:8];
            default: tx_byte = 8'h00;
        endcase
    end

    always @(*) begin
        case (state)
            S_HDR0, S_HDR1, S_TYPE, S_SEQ, S_WLOW, S_WHIGH, S_CRC0, S_CRC1:
                tx_valid = 1'b1;
            default:
                tx_valid = 1'b0;
        endcase
    end

    link_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (tx_byte),
        .valid (tx_valid),
        .ready (tx_ready),
        .tx    (tx)
    );

    // CRC16/CCITT-FALSE, one byte per clock.
    function automatic [15:0] crc_byte(input [15:0] c_in, input [7:0] d);
        reg [15:0] c;
        integer i;
        begin
            c = c_in ^ {d, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_byte = c;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            type_r      <= 8'd0;
            seq_r       <= 8'd0;
            w           <= 9'd0;
            n_words     <= 9'd0;
            word_r      <= 16'd0;
            crc         <= 16'hFFFF;
            wload_cnt   <= 2'd0;
            pay_addr    <= 9'd0;
            frames_sent <= 32'd0;
            for (si = 0; si < 4; si = si + 1) seq_ctr[si] <= 8'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy      <= 1'b1;
                        type_r    <= frame_type;
                        crc       <= 16'hFFFF;
                        w         <= 9'd0;
                        wload_cnt <= 2'd0;
                        pay_addr  <= 9'd0;
                        case (frame_type)
                            8'h01: n_words <= 9'd256;
                            8'h02: n_words <= 9'd64;
                            8'h03: n_words <= 9'd256;
                            8'h04: n_words <= 9'd8;
                            default: n_words <= 9'd0;
                        endcase
                        case (frame_type)
                            8'h01: begin seq_r <= seq_ctr[0]; seq_ctr[0] <= seq_ctr[0] + 8'd1; end
                            8'h02: begin seq_r <= seq_ctr[1]; seq_ctr[1] <= seq_ctr[1] + 8'd1; end
                            8'h03: begin seq_r <= seq_ctr[2]; seq_ctr[2] <= seq_ctr[2] + 8'd1; end
                            default: begin seq_r <= seq_ctr[3]; seq_ctr[3] <= seq_ctr[3] + 8'd1; end
                        endcase
                        state <= S_HDR0;
                    end
                end

                S_HDR0:  if (tx_ready) state <= S_HDR1;
                S_HDR1:  if (tx_ready) state <= S_TYPE;
                S_TYPE:  if (tx_ready) begin
                             crc   <= crc_byte(crc, type_r);
                             state <= S_SEQ;
                         end
                S_SEQ:   if (tx_ready) begin
                             crc   <= crc_byte(crc, seq_r);
                             pay_addr <= 9'd0;
                             state <= (n_words == 9'd0) ? S_CRC0 : S_WLOAD;
                         end

                S_WLOAD: begin
                    // pay_addr has been stable since the previous state; two
                    // clocks cover the payload buffer's registered read.
                    if (wload_cnt == 2'd0) begin
                        wload_cnt <= 2'd1;
                    end else begin
                        word_r    <= pay_word;
                        wload_cnt <= 2'd0;
                        state     <= S_WLOW;
                    end
                end

                S_WLOW:  if (tx_ready) begin
                             crc   <= crc_byte(crc, word_r[7:0]);
                             state <= S_WHIGH;
                         end
                S_WHIGH: if (tx_ready) begin
                             crc <= crc_byte(crc, word_r[15:8]);
                             if (w + 9'd1 == n_words) begin
                                 state <= S_CRC0;
                             end else begin
                                 w        <= w + 9'd1;
                                 pay_addr <= w + 9'd1;
                                 state    <= S_WLOAD;
                             end
                         end

                S_CRC0:  if (tx_ready) state <= S_CRC1;
                S_CRC1:  if (tx_ready) state <= S_DONE;

                S_DONE: begin
                    busy        <= 1'b0;
                    done        <= 1'b1;
                    frames_sent <= frames_sent + 32'd1;
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
