`timescale 1ns/1ps

// Twelve pressure-controlled DDS voices and four physical-button flute voices.
module audio_voice_core #(
    parameter integer DEBOUNCE_CYCLES = 122880,
    parameter integer AUTO_PLAY_ENABLED = 0,
    parameter [11:0] PIANO_FIXED_FORCE = 12'd2048
)(
    input  wire       sys_clk,
    input  wire       reset_n,
    input  wire [3:0] flute_key_n,
    input  wire       vibrato_key_n,
    input  wire       mute,
    input  wire [9:0] master_gain,
    output wire       max_bclk,
    output wire       max_lrclk,
    output wire       max_din,
    output wire       audio_clk,
    output wire       audio_rst,
    output wire       pcm_ready,
    input wire        piano_mode,
    input wire        piano_link_alive,
    input wire [7:0]  piano_base_note,
    input wire [47:0] piano_pressed,
    // Retained for packet/interface compatibility; pressure does not control sound.
    input wire [143:0] piano_force
);
    audio_clock_gowin clocks (
        .sys_clk(sys_clk),
        .rst_n(reset_n),
        .audio_clk(audio_clk),
        .audio_rst(audio_rst)
    );

    reg [7:0] sample_div;
    always @(posedge audio_clk) begin
        if (audio_rst)
            sample_div <= 0;
        else
            sample_div <= sample_div + 1'b1;
    end
    wire sample_tick = (sample_div == 0);

    genvar key_index;

    (* syn_preserve=1, async_reg="true" *) reg mute_meta, mute_audio;
    always @(posedge audio_clk) begin
        if (audio_rst) begin
            mute_meta <= 1'b1;
            mute_audio <= 1'b1;
        end else begin
            mute_meta <= mute;
            mute_audio <= mute_meta;
        end
    end
    wire [3:0] flute_key_down;
    wire auto_mode;
    wire [11:0] auto_keys;
    piano_auto_player player (
        .clk(audio_clk),
        .rst(audio_rst),
        .sample_tick(sample_tick),
        .toggle_combo(AUTO_PLAY_ENABLED && flute_key_down[0] && flute_key_down[3]),
        .auto_mode(auto_mode),
        .keys(auto_keys)
    );
    reg auto_mode_d;
    always @(posedge audio_clk) begin
        if (audio_rst)
            auto_mode_d <= 0;
        else
            auto_mode_d <= auto_mode;
    end
    wire mode_change = auto_mode != auto_mode_d;
    wire sound_reset = audio_rst || mode_change || (!auto_mode && mute_audio);
    wire [7:0] selected_base = auto_mode ? 8'd60 : piano_base_note;
    wire [9:0] selected_gain = auto_mode ? 10'd300 : master_gain;
    wire [47:0] piano_key_down = auto_mode ? {36'd0, auto_keys} :
        ((piano_mode && piano_link_alive && !mute_audio) ? piano_pressed : 48'd0);
    wire vibrato_pressed;
    reg vibrato_pressed_d;
    reg vibrato_enabled;
    key_filter #(
        .STABLE_CYCLES(DEBOUNCE_CYCLES)
    ) vibrato_button (
        .clk(audio_clk),
        .rst(audio_rst),
        .key_n(vibrato_key_n),
        .key_down(vibrato_pressed)
    );
    always @(posedge audio_clk) begin
        if (audio_rst) begin
            vibrato_pressed_d <= 0;
            vibrato_enabled <= 0;
        end else begin
            vibrato_pressed_d <= vibrato_pressed;
            if (vibrato_pressed && !vibrato_pressed_d)
                vibrato_enabled <= !vibrato_enabled;
        end
    end
    // One common LFO saves logic; each voice scales it by its own DDS frequency.
    wire [31:0] lfo_step;
    wire signed [6:0] vibrato_lfo = $signed(lfo_step - 32'd8192);
    piano_vibrato #(
        .TICK_SAMPLES(100),
        .DEPTH_SHIFT(13),
        .DELAY_SAMPLES(9600),
        .RAMP_SAMPLES(400)
    ) shared_vibrato (
        .clk(audio_clk),
        .rst(sound_reset || !vibrato_enabled),
        .note_on(1'b0),
        .sample_tick(sample_tick),
        .base_step(32'd8192),
        .modulated_step(lfo_step)
    );
    wire [383:0] voice_steps, vibrato_deltas;
    wire [83:0] voice_notes, vibrato_notes;
    piano_vibrato_bank vibrato_bank (
        .clk(audio_clk),
        .rst(sound_reset || !vibrato_enabled),
        .sample_tick(sample_tick),
        .lfo(vibrato_lfo),
        .steps(voice_steps),
        .notes(voice_notes),
        .deltas(vibrato_deltas),
        .tags(vibrato_notes)
    );
    wire [11:0] voice_gate, voice_active;
    wire [71:0] voice_owner;
    piano_key_allocator allocator (
        .clk(audio_clk),
        .rst(sound_reset),
        .keys(piano_key_down),
        .active(voice_active),
        .gate(voice_gate),
        .owners(voice_owner)
    );
    wire signed [15:0] piano_channel [0:11];
    generate
        for (key_index = 0; key_index < 12; key_index = key_index + 1) begin : piano_voices
            wire [8:0] piano_note_ext = {1'b0,selected_base} + {3'd0, voice_owner[key_index*6 +: 6]};
            wire [6:0] piano_note = (piano_note_ext > 9'd127) ? 7'd127 : piano_note_ext[6:0];
            assign voice_notes[key_index*7 +: 7] = piano_note;
            piano_voice_simple #(
                .SEED(32'h13579bdf)
            ) piano (
                .clk(audio_clk),
                .rst(sound_reset),
                .sample_tick(sample_tick),
                .key_down(voice_gate[key_index]),
                .midi(piano_note),
                .force_value(PIANO_FIXED_FORCE),
                .vibrato_delta(vibrato_deltas[key_index*32 +: 32]),
                .vibrato_note(vibrato_notes[key_index*7 +: 7]),
                .base_step_out(voice_steps[key_index*32 +: 32]),
                .voice(piano_channel[key_index]),
                .active(voice_active[key_index])
            );
        end
    endgenerate

    // Four independent external buttons; the existing global mute applies.
    wire signed [15:0] flute_channel [0:3];
    generate
        for (key_index=0; key_index<4; key_index=key_index+1) begin : flute_voices
            // C5, E5, G5, C6 at 96 kHz.
            localparam [31:0] STEP = key_index==0 ? 32'd23409859 :
                key_index==1 ? 32'd29494573 :
                key_index==2 ? 32'd35075158 : 32'd46819719;
            key_filter #(
                .STABLE_CYCLES(DEBOUNCE_CYCLES)
            ) button (
                .clk(audio_clk),
                .rst(audio_rst),
                .key_n(flute_key_n[key_index]),
                .key_down(flute_key_down[key_index])
            );
            flute_voice #(
                .PHASE_STEP(STEP)
            ) flute (
                .clk(audio_clk),
                .rst(sound_reset),
                .sample_tick(sample_tick),
                .key_down(flute_key_down[key_index] && !mute_audio && !auto_mode &&
                    !(AUTO_PLAY_ENABLED && flute_key_down[0] && flute_key_down[3])),
                .voice(flute_channel[key_index]),
                .active()
            );
        end
    endgenerate

    // Channels 0..11: piano; channels 12..15: flute, including release tails.
    wire [255:0] mixer_samples;
    generate
        for (key_index = 0; key_index < 12; key_index = key_index + 1) begin : mix_piano
            assign mixer_samples[key_index*16 +: 16] = piano_channel[key_index];
        end
        for (key_index = 0; key_index < 4; key_index = key_index + 1) begin : mix_flute
            assign mixer_samples[(12+key_index)*16 +: 16] = flute_channel[key_index];
        end
    endgenerate

    wire signed [15:0] pcm_sample;
    wire [4:0] mix_active_count;
    wire [15:0] mix_gain_q15;
    wire mix_clipped;
    adaptive_voice_mixer #(
        .CHANNELS(16)
    ) mixer (
        .clk(audio_clk),
        .rst(sound_reset),
        .sample_tick(sample_tick),
        .samples(mixer_samples),
        .pcm(pcm_sample),
        .active_count(mix_active_count),
        .gain_q15(mix_gain_q15),
        .clipped(mix_clipped)
    );

    wire signed [15:0] output_pcm;
    master_volume volume (
        .clk(audio_clk),
        .rst(sound_reset),
        .sample_tick(sample_tick),
        .gain(selected_gain),
        .pcm_in(pcm_sample),
        .pcm_out(output_pcm)
    );

    max98357_tx #(
        .DATA_WIDTH(16),
        .SAMPLE_RATE(96000),
        .AUDIO_CLK_HZ(24576000)
    ) tx (
        .clk(audio_clk),
        .rst(audio_rst),
        .pcm_left(output_pcm),
        .pcm_right(output_pcm),
        .pcm_valid(1'b1),
        .pcm_ready(pcm_ready),
        .bclk(max_bclk),
        .lrclk(max_lrclk),
        .din(max_din)
    );
endmodule

// Score events, not recorded PCM. Default 120 BPM, 80% note gate.
module piano_auto_player #(
    parameter integer HOLD_SAMPLES = 96000,
    parameter integer BEAT_SAMPLES = 48000,
    parameter integer GAP_SAMPLES = 9600,
    parameter integer LOOP_PLAY = 1
)(
    input wire clk,
    input wire rst,
    input wire sample_tick,
    input wire toggle_combo,
    output reg auto_mode,
    output wire [11:0] keys
);
    reg [31:0] hold_count, elapsed;
    reg combo_latched, finished;
    reg [5:0] event_index;
    reg [3:0] note_index;
    wire long_note = event_index == 6 || event_index == 13 ||
        event_index == 20 || event_index == 27 || event_index == 34 || event_index == 41;
    wire [31:0] duration = long_note ? BEAT_SAMPLES*2 : BEAT_SAMPLES;
    assign keys = (auto_mode && !finished && elapsed < duration-GAP_SAMPLES) ?
        (12'd1 << note_index) : 12'd0;
    always @* begin
        case (event_index)
            6'd0: note_index = 4'd0;
            6'd1: note_index = 4'd0;
            6'd2: note_index = 4'd7;
            6'd3: note_index = 4'd7;
            6'd4: note_index = 4'd9;
            6'd5: note_index = 4'd9;
            6'd6: note_index = 4'd7;
            6'd7: note_index = 4'd5;
            6'd8: note_index = 4'd5;
            6'd9: note_index = 4'd4;
            6'd10: note_index = 4'd4;
            6'd11: note_index = 4'd2;
            6'd12: note_index = 4'd2;
            6'd13: note_index = 4'd0;
            6'd14: note_index = 4'd7;
            6'd15: note_index = 4'd7;
            6'd16: note_index = 4'd5;
            6'd17: note_index = 4'd5;
            6'd18: note_index = 4'd4;
            6'd19: note_index = 4'd4;
            6'd20: note_index = 4'd2;
            6'd21: note_index = 4'd7;
            6'd22: note_index = 4'd7;
            6'd23: note_index = 4'd5;
            6'd24: note_index = 4'd5;
            6'd25: note_index = 4'd4;
            6'd26: note_index = 4'd4;
            6'd27: note_index = 4'd2;
            6'd28: note_index = 4'd0;
            6'd29: note_index = 4'd0;
            6'd30: note_index = 4'd7;
            6'd31: note_index = 4'd7;
            6'd32: note_index = 4'd9;
            6'd33: note_index = 4'd9;
            6'd34: note_index = 4'd7;
            6'd35: note_index = 4'd5;
            6'd36: note_index = 4'd5;
            6'd37: note_index = 4'd4;
            6'd38: note_index = 4'd4;
            6'd39: note_index = 4'd2;
            6'd40: note_index = 4'd2;
            6'd41: note_index = 4'd0;
            default: note_index = 0;
        endcase
    end
    always @(posedge clk) begin
        if (rst) begin
            auto_mode <= 0;
            hold_count <= 0;
            elapsed <= 0;
            event_index <= 0;
            combo_latched <= 0;
            finished <= 0;
        end else begin
            if (!toggle_combo) begin
                hold_count <= 0;
                combo_latched <= 0;
            end
            if (sample_tick) begin
                if (toggle_combo && !combo_latched) begin
                    if (hold_count == HOLD_SAMPLES-1) begin
                        auto_mode <= !auto_mode;
                        combo_latched <= 1;
                        hold_count <= 0;
                        elapsed <= 0;
                        event_index <= 0;
                        finished <= 0;
                    end else
                        hold_count <= hold_count + 1'b1;
                end
                // Toggle has priority over score progression.
                if (!(toggle_combo && !combo_latched && hold_count == HOLD_SAMPLES-1)) begin
                    if (auto_mode && !finished) begin
                        if (elapsed == duration-1) begin
                            elapsed <= 0;
                            if (event_index == 41) begin
                                event_index <= 0;
                                if (!LOOP_PLAY) finished <= 1;
                            end else
                                event_index <= event_index + 1'b1;
                        end else
                            elapsed <= elapsed + 1'b1;
                    end
                end
            end
        end
    end
endmodule

// 48 physical keys share 12 voices. Scans one key per clock.
// Allocation preference: same released key, idle, release tail, round-robin steal.
module piano_key_allocator (
    input wire clk,
    input wire rst,
    input wire [47:0] keys,
    input wire [11:0] active,
    output reg [11:0] gate,
    output wire [71:0] owners
);
    reg [5:0] owner [0:11];
    reg [11:0] valid;
    reg [47:0] seen;
    reg [5:0] scan;
    reg [3:0] steal, pending_voice;
    reg pending;
    integer i, choice;
    genvar g;
    generate
        for (g = 0; g < 12; g = g + 1) begin : pack
            assign owners[g*6 +: 6] = owner[g];
        end
    endgenerate
    always @* begin
        choice = -1;
        for (integer j = 0; j < 12; j = j + 1)
            if (choice < 0 && valid[j] && owner[j] == scan)
                choice = j;
        for (integer j = 0; j < 12; j = j + 1)
            if (choice < 0 && !gate[j] && !active[j])
                choice = j;
        for (integer j = 0; j < 12; j = j + 1)
            if (choice < 0 && !gate[j])
                choice = j;
        if (choice < 0)
            choice = steal;
    end
    always @(posedge clk) begin
        if (rst) begin
            gate <= 0;
            valid <= 0;
            seen <= 0;
            scan <= 0;
            steal <= 0;
            pending <= 0;
            pending_voice <= 0;
            for (i = 0; i < 12; i = i + 1)
                owner[i] <= 0;
        end else if (pending) begin
            // A complete low clock lets note_on retrigger when a voice is reused.
            gate[pending_voice] <= keys[owner[pending_voice]];
            pending <= 0;
        end else begin
            seen[scan] <= keys[scan];
            if (keys[scan] && !seen[scan]) begin
                owner[choice] <= scan;
                valid[choice] <= 1;
                gate[choice] <= 0;
                pending_voice <= choice;
                pending <= 1;
                steal <= choice == 11 ? 0 : choice + 1;
            end else if (!keys[scan]) begin
                for (i = 0; i < 12; i = i + 1)
                    if (valid[i] && owner[i] == scan)
                        gate[i] <= 0;
            end
            scan <= scan == 47 ? 0 : scan + 1'b1;
        end
    end
endmodule

// 12 voices x 8 clocks = 96 clocks, comfortably within a 256-clock sample.
module piano_vibrato_bank #(
    parameter integer DEPTH_SHIFT = 13
)(
    input wire clk,
    input wire rst,
    input wire sample_tick,
    input wire signed [6:0] lfo,
    input wire [383:0] steps,
    input wire [83:0] notes,
    output reg [383:0] deltas,
    output reg [83:0] tags
);
    reg [3:0] index, state;
    reg [31:0] held_step;
    reg [6:0] held_note;
    wire [31:0] modulated;
    piano_vibrato_offset #(
        .DEPTH_SHIFT(DEPTH_SHIFT)
    ) calculator (
        .clk(clk),
        .rst(rst),
        .sample_tick(state == 1),
        .base_step(held_step),
        .midi(held_note),
        .lfo(lfo),
        .modulated_step(modulated)
    );
    always @(posedge clk) begin
        if (rst) begin
            index <= 0;
            state <= 0;
            held_step <= 0;
            held_note <= 0;
            deltas <= 0;
            tags <= 0;
        end else if (sample_tick) begin
            index <= 0;
            held_step <= steps[31:0];
            held_note <= notes[6:0];
            state <= 1;
        end else if (state != 0) begin
            if (state == 8) begin
                deltas[index*32 +: 32] <= modulated-held_step;
                tags[index*7 +: 7] <= held_note;
                if (index == 11)
                    state <= 0;
                else begin
                    index <= index+1'b1;
                    held_step <= steps[(index+1)*32 +: 32];
                    held_note <= notes[(index+1)*7 +: 7];
                    state <= 1;
                end
            end else
                state <= state+1'b1;
        end
    end
endmodule
