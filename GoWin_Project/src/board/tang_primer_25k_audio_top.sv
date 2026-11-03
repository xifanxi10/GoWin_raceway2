`timescale 1ns/1ps

// Tang Primer 25K board image with the existing MCU link feeding the
// teammate's four-voice pressure audio engine.
//
// The MCU protocol and mcu_link_top are intentionally reused unchanged.
// Audio-only configuration fields that have no input on the teammate KS core
// remain in the communication registers and are not claimed as implemented.
module tang_primer_25k_audio_top #(
    parameter integer RESET_HOLD_CLKS = 500000,
    parameter integer PRESSURE_ON_LEVEL = 300,
    parameter integer PRESSURE_OFF_LEVEL = 200,
    parameter integer PRESSURE_FULL_LEVEL = 3000,
    parameter integer PRESSURE_CONFIRM_FRAMES = 2,
    parameter integer MIN_PRESSURE_VELOCITY = 64,
    // K4..K1 resting ADC offsets, from the user's latest measurements.
    parameter [47:0] PRESSURE_BASELINES = {12'd0, 12'd710, 12'd430, 12'd0}
)(
    input  wire clk,
    input  wire reset_button,
    input  wire pressure_rx,
    input  wire [3:0] flute_key_n,
    input  wire vibrato_key_n,
    input  wire ctrl_rx,
    output wire ctrl_tx,
    output wire max_bclk,
    output wire max_lrclk,
    output wire max_din,
    // Second copy of the I2S stream for the visualisation co-processor board.
    // Read-only fan-out: the audio path and the MAX98357A wiring are unchanged.
    output wire i2s_mon_bclk,
    output wire i2s_mon_lrclk,
    output wire i2s_mon_sd
);
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

    (* syn_keep=1 *) wire [95:0] pressure;
    (* syn_keep=1 *) wire [15:0] pressure_seq;
    (* syn_keep=1 *) wire pressure_valid, pressure_link_alive, pressure_timeout_event;
    (* syn_keep=1 *) wire source_mode, source_link_alive, source_changed, source_timeout_event;
    (* syn_keep=1 *) wire [7:0] piano_base_note;
    (* syn_keep=1 *) wire [15:0] piano_sequence;
    (* syn_keep=1 *) wire [47:0] piano_pressed;
    (* syn_keep=1 *) wire [143:0] piano_force;
    (* syn_keep=1 *) wire piano_snapshot_valid, piano_link_alive;
    (* syn_keep=1 *) wire [47:0] piano_rearm_required;
    (* syn_keep=1 *) wire [319:0] piano_diagnostics;
    (* syn_keep=1 *) wire timbre, mode, mute;
    (* syn_keep=1 *) wire signed [7:0] transpose;
    (* syn_keep=1 *) wire [9:0] gain;
    (* syn_keep=1 *) wire [63:0] key_notes;
    (* syn_keep=1 *) wire [31:0] chord_counts, cfg_version;
    (* syn_keep=1 *) wire [255:0] chord_notes;
    (* syn_keep=1 *) wire cfg_commit, release_all_event, release_valid;
    (* syn_keep=1 *) wire [7:0] rearm_required;
    (* syn_keep=1 *) wire [767:0] diagnostics;

    wire release_ready;
    wire [7:0] keys_released;
    wire [3:0] pressure_key_down;
    wire [31:0] pressure_strength;
    wire audio_clk;
    wire audio_rst;
    // Legacy four-key debug field is inactive; KS voices have been removed.
    wire [3:0] audio_key_down = 4'b0000;
    wire pcm_ready;

    (* syn_noprune=1, syn_preserve=1 *) mcu_link_top #(
        .CLK_HZ(50000000)
    ) link (
        .clk(clk),
        .reset_n(core_reset_n),
        .pressure_rx(pressure_rx),
        .ctrl_rx(ctrl_rx),
        .ctrl_tx(ctrl_tx),
        .cfg_ready(1'b1),
        .release_ready(release_ready),
        .keys_released(keys_released),
        .pressure(pressure),
        .pressure_seq(pressure_seq),
        .pressure_valid(pressure_valid),
        .pressure_link_alive(pressure_link_alive),
        .pressure_timeout_event(pressure_timeout_event),
        .source_mode(source_mode),
        .source_link_alive(source_link_alive),
        .source_changed(source_changed),
        .source_timeout_event(source_timeout_event),
        .piano_base_note(piano_base_note),
        .piano_sequence(piano_sequence),
        .piano_pressed(piano_pressed),
        .piano_force(piano_force),
        .piano_snapshot_valid(piano_snapshot_valid),
        .piano_link_alive(piano_link_alive),
        .piano_rearm_required(piano_rearm_required),
        .piano_diagnostics(piano_diagnostics),
        .timbre(timbre),
        .mode(mode),
        .mute(mute),
        .transpose(transpose),
        .gain(gain),
        .key_notes(key_notes),
        .chord_counts(chord_counts),
        .chord_notes(chord_notes),
        .cfg_commit(cfg_commit),
        .cfg_version(cfg_version),
        .release_all_event(release_all_event),
        .release_valid(release_valid),
        .rearm_required(rearm_required),
        .diagnostics(diagnostics)
    );

    // Keep the MCU/raw pressure snapshot intact. Apply calibration only at
    // the audio consumer, using saturated subtraction to avoid underflow.
    wire [95:0] pressure_for_keys;
    genvar pressure_index;
    generate
        for (pressure_index = 0; pressure_index < 4; pressure_index = pressure_index + 1) begin : calibration
            wire [11:0] raw_adc = pressure[pressure_index*12 +: 12];
            wire [11:0] baseline = PRESSURE_BASELINES[pressure_index*12 +: 12];
            assign pressure_for_keys[pressure_index*12 +: 12] =
                (raw_adc > baseline) ? raw_adc - baseline : 48'd0;
            // The link consumes release evidence on its original commit
            // cycle. Keep this aligned with pressure_valid, not the audio
            // consumer's one-cycle pipeline below.
            assign keys_released[pressure_index] = pressure_valid && pressure_link_alive &&
                pressure_for_keys[pressure_index*12 +: 12] <= PRESSURE_OFF_LEVEL;
        end
    endgenerate
    assign pressure_for_keys[95:48] = pressure[95:48];
    assign keys_released[7:4] = 4'b0000;

    // Split baseline subtraction from the teammate's peak/velocity multiply
    // to meet 50 MHz timing. Data and valid advance together, by one clock.
    reg [95:0] pressure_keys_sample;
    reg pressure_keys_valid;
    always @(posedge clk or negedge core_reset_n) begin
        if (!core_reset_n) begin
            pressure_keys_sample <= 0;
            pressure_keys_valid <= 0;
        end else begin
            pressure_keys_valid <= pressure_valid;
            if (pressure_valid) pressure_keys_sample <= pressure_for_keys;
        end
    end

    pressure_keys #(
        .ON_LEVEL(PRESSURE_ON_LEVEL),
        .OFF_LEVEL(PRESSURE_OFF_LEVEL),
        .FULL_LEVEL(PRESSURE_FULL_LEVEL),
        .CONFIRM_FRAMES(PRESSURE_CONFIRM_FRAMES)
    ) pressure_to_keys (
        .clk(clk),
        .reset_n(core_reset_n),
        .pressure(pressure_keys_sample),
        .pressure_valid(pressure_keys_valid),
        .pressure_link_alive(pressure_link_alive),
        .release_valid(release_valid),
        .mute(mute),
        .rearm_required(rearm_required),
        .release_ready(release_ready),
        .keys_released(),
        .key_down(pressure_key_down),
        .strength(pressure_strength)
    );

    // The teammate mailbox is a bundled-data, latest-state handshake.  Its
    // source is the 50 MHz protocol domain and its destination is the PLL
    // audio clock domain.
    wire [3:0] pressure_source_keys =
        (source_mode==1'b0 && source_link_alive) ? pressure_key_down : 4'd0;
    wire [35:0] pressure_packet_src = {pressure_strength, pressure_source_keys};
    (* syn_keep=1 *) wire [35:0] pressure_packet_audio;
    wire [31:0] note_packet_src;
    wire [35:0] note_packet_src_ext = {4'd0, note_packet_src};
    (* syn_keep=1 *) wire [35:0] note_packet_audio_ext;
    wire [31:0] note_packet_audio = note_packet_audio_ext[31:0];

    pressure_audio_bridge pressure_cdc (
        .src_clk(clk),
        .dst_clk(audio_clk),
        .reset_async(!core_reset_n),
        .src_data(pressure_packet_src),
        .dst_data(pressure_packet_audio)
    );

    wire [47:0] piano_source_pressed =
        (source_mode && source_link_alive && !release_valid) ?
            (piano_pressed & ~piano_rearm_required) : 48'd0;
    wire [211:0] piano_packet_src = {
        gain, source_mode, source_link_alive, piano_base_note,
        piano_source_pressed, piano_force
    };
    (* syn_keep=1 *) wire [211:0] piano_packet_audio;
    pressure_audio_bridge #(
        .WIDTH(212)
    ) piano_cdc (
        .src_clk(clk),
        .dst_clk(audio_clk),
        .reset_async(!core_reset_n),
        .src_data(piano_packet_src),
        .dst_data(piano_packet_audio)
    );
    wire [9:0] master_gain_audio = piano_packet_audio[211:202];
    wire piano_mode_audio = piano_packet_audio[201];
    wire piano_alive_audio = piano_packet_audio[200];
    wire [7:0] piano_base_audio = piano_packet_audio[199:192];
    wire [47:0] piano_pressed_audio = piano_packet_audio[191:144];
    wire [143:0] piano_force_audio = piano_packet_audio[143:0];

    function automatic [7:0] note_with_transpose;
        input [7:0] base_note;
        input signed [7:0] shift;
        integer signed value;
        begin
            value = $signed({1'b0, base_note}) + $signed(shift);
            if (value < 0)
                note_with_transpose = 8'd0;
            else if (value > 127)
                note_with_transpose = 8'd127;
            else
                note_with_transpose = value[7:0];
        end
    endfunction

    integer note_index;
    reg [31:0] note_packet_src_reg;
    always @* begin
        note_packet_src_reg = 32'd0;
        for (note_index = 0; note_index < 4; note_index = note_index + 1)
            note_packet_src_reg[note_index*8 +: 8] =
                note_with_transpose(key_notes[note_index*8 +: 8], transpose);
    end
    assign note_packet_src = note_packet_src_reg;

    pressure_audio_bridge notes_cdc (
        .src_clk(clk),
        .dst_clk(audio_clk),
        .reset_async(!core_reset_n),
        .src_data(note_packet_src_ext),
        .dst_data(note_packet_audio_ext)
    );

    audio_voice_core #(
        .AUTO_PLAY_ENABLED(1)
    ) audio (
        .sys_clk(clk),
        .reset_n(core_reset_n),
        .flute_key_n(flute_key_n),
        .vibrato_key_n(vibrato_key_n),
        .mute(mute),
        .master_gain(master_gain_audio),
        .max_bclk(max_bclk),
        .max_lrclk(max_lrclk),
        .max_din(max_din),
        .audio_clk(audio_clk),
        .audio_rst(audio_rst),
        .pcm_ready(pcm_ready),
        .piano_mode(piano_mode_audio),
        .piano_link_alive(piano_alive_audio),
        .piano_base_note(piano_base_audio),
        .piano_pressed(piano_pressed_audio),
        .piano_force(piano_force_audio)
    );

    // Keep the generated clock and the main audio handoff visible to the
    // implementation reports for bring-up/debugging.
    (* syn_keep=1 *) wire [31:0] audio_debug = {
        16'd0, pcm_ready, audio_rst, audio_key_down,
        pressure_link_alive, mute, cfg_commit, release_valid,
        pressure_valid, pressure_timeout_event, audio_clk
    };

    // Visualisation co-processor tap.  Same registers that drive the MAX98357A,
    // so the second board sees exactly the bits the amplifier sees.
    assign i2s_mon_bclk  = max_bclk;
    assign i2s_mon_lrclk = max_lrclk;
    assign i2s_mon_sd    = max_din;
endmodule
