// Byte 0 lives in bits [7:0]. Full sliding window retains every suffix on
// failure; a CRC-valid frame consumes the whole window, including embedded headers.
// CRC is serialized one byte per clock, safely below the UART byte interval.
module link_frame_rx #(
    parameter integer N=16,
    parameter [15:0] HEADER=16'ha55a,
    parameter integer GAP_CLKS=500000
)(
    input wire clk, rst_n,
    input wire [7:0] data,
    input wire valid, abort_frame, enable,
    output reg [N*8-1:0] frame,
    output reg frame_valid,
    output reg candidate_active,
    output reg [31:0] good_count, crc_error_count, gap_count, overflow_count
);
    import link_pkg::*;
    reg [N*8-1:0] window_data;
    wire [N*8-1:0] shifted={data,window_data[N*8-1:8]};
    reg [$clog2(N+1)-1:0] used;
    reg [$clog2(GAP_CLKS+1)-1:0] gap;
    reg checking;
    reg [7:0] previous_byte;
    reg [$clog2(N)-1:0] index;
    reg [15:0] crc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_data<=0; frame<=0; used<=0; gap<=0; checking<=0;
            index<=0; crc<=16'hffff; frame_valid<=0; candidate_active<=0;
            previous_byte<=0;
            good_count<=0; crc_error_count<=0; gap_count<=0; overflow_count<=0;
        end else begin
            frame_valid<=0;
            if (!enable) begin
                used<=0; gap<=0; checking<=0; candidate_active<=0; previous_byte<=0;
            end else begin
            if (used!=0 && !valid) begin
                if (gap==GAP_CLKS-1) begin
                    used<=0; gap<=0; checking<=0; candidate_active<=0;
                    gap_count<=gap_count+1'b1;
                end
                else gap<=gap+1'b1;
            end
            if (valid) begin
                gap<=0;
                window_data<=shifted;
                // Claim the stream as soon as the two-byte header arrives;
                // the other fixed-length parser is disabled from the next
                // clock, so payload bytes cannot start a nested candidate.
                if (!checking && !candidate_active && used!=0 &&
                    previous_byte==HEADER[7:0] && data==HEADER[15:8])
                    candidate_active<=1;
                previous_byte<=data;
                if (used<N) used<=used+1'b1;
                if (checking) overflow_count<=overflow_count+1'b1;
                else if (used>=N-1 && shifted[15:0]==HEADER) begin
                    frame<=shifted; checking<=1; candidate_active<=1; index<=2; crc<=16'hffff;
                end
            end
            if (checking) begin
                if (index<N-2) begin
                    crc<=crc_byte(crc,frame[index*8+:8]); index<=index+1'b1;
                end else begin
                    checking<=0;
                    candidate_active<=0;
                    if (crc==frame[(N-2)*8+:16]) begin
                        frame_valid<=1; good_count<=good_count+1'b1; used<=0; gap<=0;
                    end else crc_error_count<=crc_error_count+1'b1;
                end
            end
            if (abort_frame) begin used<=0; gap<=0; checking<=0; frame_valid<=0; end
            if (abort_frame) candidate_active<=0;
            end
        end
    end
endmodule
