// Integration top / same-clock downstream interface, NOT a pin-constrained board wrapper.
module mcu_link_top #(
    parameter integer CLK_HZ=50000000,
    parameter integer PRESSURE_BAUD=1000000, CTRL_BAUD=115200,
    parameter integer PRESSURE_TIMEOUT_MS=20, PIANO_TIMEOUT_MS=75,
    parameter integer FRAME_GAP_MS=5, REPLY_DEPTH=4
)(
    input wire clk, reset_n,
    input wire pressure_rx, ctrl_rx,
    output wire ctrl_tx,
    input wire cfg_ready, release_ready,
    // From a calibrated same-clock key detector; 1 means genuinely released.
    // Tie to zero until that detector exists. No guessed ADC threshold here.
    input wire [7:0] keys_released,
    output wire [95:0] pressure,
    output wire [15:0] pressure_seq,
    output wire pressure_valid, pressure_link_alive, pressure_timeout_event,
    output wire source_mode, source_link_alive, source_changed, source_timeout_event,
    output wire [7:0] piano_base_note,
    output wire [15:0] piano_sequence,
    output wire [47:0] piano_pressed,
    output wire [143:0] piano_force,
    output wire piano_snapshot_valid, piano_link_alive,
    output wire [47:0] piano_rearm_required,
    output wire [319:0] piano_diagnostics,
    output wire timbre, mode, mute,
    output wire signed [7:0] transpose,
    output wire [9:0] gain,
    output wire [63:0] key_notes,
    output wire [31:0] chord_counts,
    output wire [255:0] chord_notes,
    output wire cfg_commit,
    output wire [31:0] cfg_version,
    output wire release_all_event,
    output reg release_valid,
    output reg [7:0] rearm_required,
    // Word indices documented in docs/FPGA_LINK.md. Counters wrap modulo 2^32.
    output wire [767:0] diagnostics
);
    (* syn_preserve=1, async_reg="true" *) reg [1:0] reset_pipe;
    wire rst_n=reset_pipe[1];
    // synthesis translate_off
    initial begin
        if (CLK_HZ < 16*PRESSURE_BAUD || CLK_HZ < 16*CTRL_BAUD)
            $fatal(1,"UART requires at least 16 clocks per bit");
        if (PRESSURE_TIMEOUT_MS<1 || FRAME_GAP_MS<1 || REPLY_DEPTH<1 || REPLY_DEPTH>8)
            $fatal(1,"Invalid watchdog, gap or reply depth (supported depth 1..8)");
    end
    // synthesis translate_on
    always @(posedge clk or negedge reset_n)
        if (!reset_n) reset_pipe<=0;
        else reset_pipe<={reset_pipe[0],1'b1};
    wire [7:0] p_data,c_data,t_data;
    wire p_valid,c_valid,t_valid,t_ready,p_err,c_err,p_break,c_break;
    wire [175:0] p_frame;
    wire [271:0] piano_frame;
    wire [127:0] c_frame,reply;
    wire p_frame_valid,piano_frame_valid,c_frame_valid,reply_valid,reply_ready;
    wire p_candidate_active,piano_candidate_active;
    wire piano_timeout_event;
    wire [31:0] piano_parser_good_count,piano_parser_crc_count;
    wire [31:0] piano_parser_gap_count,piano_parser_overflow_count;
    wire [31:0] piano_good_count,piano_field_error_count;
    wire [31:0] piano_duplicate_count,piano_discontinuity_count,piano_timeout_count;
    reg source_mode_reg, source_link_alive_reg, source_changed_reg, source_timeout_event_reg;
    reg [47:0] piano_rearm_required_reg;
    wire [31:0] d[0:23];
    reg [31:0] p_framing_count,c_framing_count,p_break_count,c_break_count;
    genvar g;
    generate for (g=0;g<24;g=g+1) begin: debug_words
        assign diagnostics[g*32+:32]=d[g];
    end endgenerate
    assign d[18]=p_framing_count; assign d[19]=c_framing_count;
    assign d[20]=p_break_count; assign d[21]=c_break_count;
    assign d[22]=cfg_version;
    assign d[23]={22'd0,rearm_required,release_valid,pressure_link_alive};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_framing_count<=0; c_framing_count<=0; p_break_count<=0; c_break_count<=0;
            release_valid<=0; rearm_required<=8'hff;
        end else begin
            if (p_err) p_framing_count<=p_framing_count+1'b1;
            if (c_err) c_framing_count<=c_framing_count+1'b1;
            if (p_break) p_break_count<=p_break_count+1'b1;
            if (c_break) c_break_count<=c_break_count+1'b1;
            if (release_valid && release_ready) release_valid<=0;
            if (pressure_valid && pressure_link_alive && source_mode_reg==1'b0)
                rearm_required<=rearm_required & ~keys_released;
            // Set dominates clear; remain disarmed until a subsequent valid release sample.
            if (release_all_event || source_timeout_event_reg || source_changed_reg) begin
                release_valid<=1; rearm_required<=8'hff;
            end
        end
    end

    // Only a complete, legal snapshot can select the active input source.
    // A source timeout is local to the currently selected protocol; frames
    // from the other protocol remain free to recover and switch the source.
    localparam integer PIANO_TIMEOUT_CLKS=(CLK_HZ/1000)*PIANO_TIMEOUT_MS;
    localparam integer PIANO_AGE_W=(PIANO_TIMEOUT_CLKS < 2) ? 1 : $clog2(PIANO_TIMEOUT_CLKS+1);
    reg [PIANO_AGE_W-1:0] piano_source_age;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            source_mode_reg<=0;
            source_link_alive_reg<=0;
            source_changed_reg<=0;
            source_timeout_event_reg<=0;
            piano_source_age<=0;
            piano_rearm_required_reg<=0;
        end else begin
            source_changed_reg<=0;
            source_timeout_event_reg<=0;
            if (pressure_valid) begin
                if (source_mode_reg!=1'b0) source_changed_reg<=1;
                source_mode_reg<=0;
                source_link_alive_reg<=1;
                piano_source_age<=0;
            end else if (piano_snapshot_valid) begin
                if (source_mode_reg!=1'b1) source_changed_reg<=1;
                source_mode_reg<=1;
                source_link_alive_reg<=1;
                piano_source_age<=0;
                if (piano_pressed==0) piano_rearm_required_reg<=0;
            end else if (source_mode_reg==1'b1 && source_link_alive_reg) begin
                if (piano_source_age == PIANO_TIMEOUT_CLKS-1) begin
                    source_link_alive_reg<=0;
                    source_timeout_event_reg<=1;
                    piano_rearm_required_reg<=48'hffffffffffff;
                end else piano_source_age<=piano_source_age+1'b1;
            end else if (source_mode_reg==1'b0 && pressure_timeout_event) begin
                source_link_alive_reg<=0;
                source_timeout_event_reg<=1;
            end else if (source_mode_reg==1'b1 && source_link_alive_reg && piano_timeout_event) begin
                source_link_alive_reg<=0;
                source_timeout_event_reg<=1;
                piano_rearm_required_reg<=48'hffffffffffff;
            end
            if (piano_snapshot_valid && source_mode_reg==1'b1 && piano_pressed==0)
                piano_rearm_required_reg<=0;
        end
    end
    assign source_mode=source_mode_reg;
    assign source_link_alive=source_link_alive_reg;
    assign source_changed=source_changed_reg;
    assign source_timeout_event=source_timeout_event_reg;
    assign piano_rearm_required=piano_rearm_required_reg;
    assign piano_diagnostics = {
        32'd0, piano_timeout_count, piano_discontinuity_count,
        piano_duplicate_count, piano_field_error_count, piano_good_count,
        piano_parser_overflow_count, piano_parser_gap_count,
        piano_parser_crc_count, piano_parser_good_count
    };
    link_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(PRESSURE_BAUD)) pressure_uart(
        .clk(clk),.rst_n(rst_n),.rx(pressure_rx),.data(p_data),.valid(p_valid),
        .framing_error(p_err),.break_event(p_break));
    link_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(CTRL_BAUD)) control_uart(
        .clk(clk),.rst_n(rst_n),.rx(ctrl_rx),.data(c_data),.valid(c_valid),
        .framing_error(c_err),.break_event(c_break));
    link_frame_rx #(.N(22),.HEADER(16'h55aa),.GAP_CLKS((CLK_HZ/1000)*FRAME_GAP_MS)) pressure_parser(
        .clk(clk),.rst_n(rst_n),.data(p_data),.valid(p_valid),.abort_frame(p_err),
        .enable(!piano_candidate_active),.frame(p_frame),.frame_valid(p_frame_valid),
        .candidate_active(p_candidate_active),.good_count(d[0]),
        .crc_error_count(d[1]),.gap_count(d[2]),.overflow_count(d[3]));
    link_frame_rx #(.N(34),.HEADER(16'h56aa),.GAP_CLKS((CLK_HZ/1000)*FRAME_GAP_MS)) piano_parser(
        .clk(clk),.rst_n(rst_n),.data(p_data),.valid(p_valid),.abort_frame(p_err),
        .enable(!p_candidate_active),.frame(piano_frame),.frame_valid(piano_frame_valid),
        .candidate_active(piano_candidate_active),.good_count(piano_parser_good_count),
        .crc_error_count(piano_parser_crc_count),.gap_count(piano_parser_gap_count),
        .overflow_count(piano_parser_overflow_count));
    pressure_receiver #(.CLK_HZ(CLK_HZ),.TIMEOUT_MS(PRESSURE_TIMEOUT_MS)) pressure_store(
        .clk(clk),.rst_n(rst_n),.frame(p_frame),.frame_valid(p_frame_valid),
        .pressure(pressure),.pressure_seq(pressure_seq),.pressure_valid(pressure_valid),
        .link_alive(pressure_link_alive),.timeout_event(pressure_timeout_event),
        .good_count(d[4]),.range_error_count(d[5]),.duplicate_seq_count(d[6]),
        .discontinuity_count(d[7]),.timeout_count(d[8]));
    piano_receiver #(.CLK_HZ(CLK_HZ),.TIMEOUT_MS(PIANO_TIMEOUT_MS)) piano_store(
        .clk(clk),.rst_n(rst_n),.frame(piano_frame),.frame_valid(piano_frame_valid),
        .base_note(piano_base_note),.seq(piano_sequence),.pressed(piano_pressed),
        .force_values(piano_force),.snapshot_valid(piano_snapshot_valid),
        .link_alive(piano_link_alive),.timeout_event(piano_timeout_event),
        .good_count(piano_good_count),.field_error_count(piano_field_error_count),
        .duplicate_sequence_count(piano_duplicate_count),
        .discontinuity_count(piano_discontinuity_count),.timeout_count(piano_timeout_count));
    link_frame_rx #(.N(16),.HEADER(16'ha55a),.GAP_CLKS((CLK_HZ/1000)*FRAME_GAP_MS)) control_parser(
        .clk(clk),.rst_n(rst_n),.data(c_data),.valid(c_valid),.abort_frame(c_err),
        .enable(1'b1),.frame(c_frame),.frame_valid(c_frame_valid),.candidate_active(),.good_count(d[9]),
        .crc_error_count(d[10]),.gap_count(d[11]),.overflow_count(d[12]));
    control_executor executor(
        .clk(clk),.rst_n(rst_n),.request(c_frame),.request_valid(c_frame_valid),
        .cfg_ready(cfg_ready),.release_ready((!release_valid || release_ready) && !release_all_event),
        .timbre(timbre),.mode(mode),.mute(mute),.transpose(transpose),.gain(gain),
        .key_notes(key_notes),.chord_counts(chord_counts),.chord_notes(chord_notes),
        .cfg_commit(cfg_commit),.cfg_version(cfg_version),.release_event(release_all_event),
        .reply(reply),.reply_valid(reply_valid),.reply_ready(reply_ready),
        .duplicate_count(d[13]),.invalid_count(d[14]),.busy_count(d[15]),.overflow_count(d[16]));
    control_reply_tx #(.DEPTH(REPLY_DEPTH)) reply_queue(
        .clk(clk),.rst_n(rst_n),.reply(reply),.reply_valid(reply_valid),.reply_ready(reply_ready),
        .tx_data(t_data),.tx_valid(t_valid),.tx_ready(t_ready),.reply_count(d[17]));
    link_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(CTRL_BAUD)) control_tx(
        .clk(clk),.rst_n(rst_n),.data(t_data),.valid(t_valid),.ready(t_ready),.tx(ctrl_tx));
endmodule
