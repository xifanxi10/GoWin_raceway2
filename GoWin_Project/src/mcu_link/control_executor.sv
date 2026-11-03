// Same-clock commit. cfg_ready gates an atomic register commit; release_ready
// means a durable event mailbox has capacity. Neither operation waits for a key.
module control_executor(
    input wire clk, rst_n,
    input wire [127:0] request,
    input wire request_valid,
    input wire cfg_ready, release_ready,
    output reg timbre, mode, mute,
    output reg signed [7:0] transpose,
    output reg [9:0] gain,
    output reg [63:0] key_notes,
    output reg [31:0] chord_counts,
    output reg [255:0] chord_notes,
    output reg cfg_commit, release_event,
    output reg [31:0] cfg_version,
    output reg [127:0] reply,
    output reg reply_valid,
    input wire reply_ready,
    output reg [31:0] duplicate_count, invalid_count, busy_count, overflow_count
);
    import link_pkg::*;
    wire [7:0] cmd=request[24+:8], target=request[48+:8];
    wire [47:0] params=request[64+:48];
    wire [7:0] p0=params[7:0];
    reg [7:0] status;
    reg known, modifies, is_release, unused_bad, value_bad;
    integer used_params, k, s, pitch, tr;
    reg next_timbre, next_mode, next_mute;
    reg signed [7:0] next_transpose;
    reg [9:0] next_gain;
    reg [63:0] next_keys;
    reg [31:0] next_counts;
    reg [255:0] next_chords;
    reg [127:0] response_body;
    reg cache_valid, cache_this, crc_busy;
    reg [127:0] cached_request, cached_reply, active_request;
    reg [15:0] crc;
    reg [3:0] crc_index;
    integer i;

    always @* begin
        next_timbre=timbre; next_mode=mode; next_mute=mute;
        next_transpose=transpose; next_gain=gain;
        next_keys=key_notes; next_counts=chord_counts; next_chords=chord_notes;
        known=1; modifies=0; is_release=0; used_params=0; value_bad=0;
        case(cmd)
            8'h00,8'h20: begin end
            8'h01: begin modifies=1; used_params=1; value_bad=p0>1; next_timbre=p0[0]; end
            8'h02: begin modifies=1; used_params=2; value_bad=params[15:0]>1000; next_gain=params[9:0]; end
            8'h03: begin
                modifies=1; used_params=1; next_transpose=$signed(p0);
                value_bad=($signed(p0)<-24 || $signed(p0)>24);
            end
            8'h04: begin
                modifies=1; used_params=1; value_bad=p0>127;
                if (target>=1 && target<=8) next_keys[(target-1)*8+:8]=p0;
            end
            8'h05: begin modifies=1; used_params=1; value_bad=p0>1; next_mode=p0[0]; end
            8'h06: begin
                modifies=1; used_params=5; value_bad=(p0<1 || p0>4);
                if (target>=1 && target<=8) begin
                    next_counts[(target-1)*4+:4]=p0[3:0];
                    next_chords[(target-1)*32+:32]=params[8+:32];
                end
                for (s=0;s<4;s=s+1)
                    if (s<p0 && params[(s+1)*8+:8]>127) value_bad=1;
            end
            8'h07: is_release=1;
            8'h08: begin modifies=1; used_params=1; value_bad=p0>1; next_mute=p0[0]; end
            // ADSR intentionally unsupported until an audio envelope consumer exists.
            default: known=0;
        endcase
        unused_bad=request[56+:8]!=0;
        for (k=0;k<6;k=k+1)
            if (k>=used_params && params[k*8+:8]!=0) unused_bad=1;
        if (cmd==8'h06)
            for (k=0;k<4;k=k+1)
                if (k>=p0 && params[(k+1)*8+:8]!=8'hff) unused_bad=1;

        // Explicit signed integer arithmetic before range checks, never 7-bit wrap.
        tr=$signed(next_transpose); pitch=0;
        if (cmd==8'h03 || cmd==8'h04 || cmd==8'h06) begin
            for (k=0;k<8;k=k+1) begin
                pitch=$signed({1'b0,next_keys[k*8+:8]})+tr;
                if (pitch<0 || pitch>127) value_bad=1;
                for (s=0;s<4;s=s+1) begin
                    pitch=$signed({1'b0,next_chords[(k*4+s)*8+:8]})+tr;
                    if (s<next_counts[k*4+:4] && (pitch<0 || pitch>127)) value_bad=1;
                end
            end
        end
        // Documented deterministic priority.
        status=0;
        if (request[16+:8]!=1) status=1;
        else if (!known) status=2;
        else if ((cmd==4 || cmd==6) ? (target<1 || target>8) : (target!=0)) status=3;
        else if (unused_bad) status=5;
        else if (value_bad) status=4;
        else if ((modifies && !cfg_ready) || (is_release && !release_ready)) status=6;

        response_body=0;
        response_body[0+:16]=16'ha55a;
        response_body[16+:8]=1;
        response_body[24+:8]=(cmd==8'h20 && status==0) ? 8'h81 : 8'h80;
        response_body[32+:16]=request[32+:16];
        response_body[48+:8]=target;
        if (cmd==8'h20 && status==0) begin
            response_body[64+:8]={7'd0,timbre};
            response_body[72+:8]={7'd0,mode};
            response_body[80+:8]=transpose;
            response_body[88+:8]={7'd0,mute};
            response_body[96+:16]={6'd0,gain};
        end else begin response_body[64+:8]=cmd; response_body[72+:8]=status; end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timbre<=0; mode<=0; mute<=1; transpose<=0; gain<=300;
            for (i=0;i<8;i=i+1) begin
                key_notes[i*8+:8]<=default_note(i);
                chord_counts[i*4+:4]<=1;
                chord_notes[i*32+:32]<={24'hffffff,default_note(i)};
            end
            cfg_commit<=0; release_event<=0; cfg_version<=0;
            reply<=0; reply_valid<=0; cache_valid<=0; cache_this<=0;
            cached_request<=0; cached_reply<=0; active_request<=0;
            crc_busy<=0; crc<=16'hffff; crc_index<=2;
            duplicate_count<=0; invalid_count<=0; busy_count<=0; overflow_count<=0;
        end else begin
            cfg_commit<=0; release_event<=0;
            if (reply_valid && reply_ready) reply_valid<=0;
            if (crc_busy) begin
                crc<=crc_byte(crc,reply[crc_index*8+:8]);
                if (crc_index==13) begin
                    reply[112+:16]<=crc_byte(crc,reply[104+:8]);
                    crc_busy<=0; reply_valid<=1;
                    if (cache_this) begin
                        cache_valid<=1; cached_request<=active_request;
                        cached_reply<={crc_byte(crc,reply[104+:8]),reply[111:0]};
                    end
                end else crc_index<=crc_index+1'b1;
            end
            if (request_valid) begin
                if (crc_busy || (reply_valid && !reply_ready)) overflow_count<=overflow_count+1'b1;
                else if (cache_valid && request==cached_request) begin
                    reply<=cached_reply; reply_valid<=1; duplicate_count<=duplicate_count+1'b1;
                end else begin
                    reply<=response_body; active_request<=request;
                    crc<=16'hffff; crc_index<=2; crc_busy<=1; reply_valid<=0;
                    cache_this<=status!=6;
                    if (status==6) busy_count<=busy_count+1'b1;
                    else if (status!=0) invalid_count<=invalid_count+1'b1;
                    else if (modifies) begin
                        timbre<=next_timbre; mode<=next_mode; mute<=next_mute;
                        transpose<=next_transpose; gain<=next_gain;
                        key_notes<=next_keys; chord_counts<=next_counts; chord_notes<=next_chords;
                        cfg_commit<=1; cfg_version<=cfg_version+1'b1;
                    end else if (is_release) release_event<=1;
                end
            end
        end
    end
endmodule
