// Tang Primer 25K core 52300 + Dock 60033 (including v1.1).
// Communication bring-up image; there is NO audio engine in this wrapper.
(* syn_preserve=1, syn_noprune=1 *) module tang_primer_25k_top #(
    parameter integer RESET_HOLD_CLKS=500000 // 10 ms at the fixed 50 MHz clock
)(
    input wire clk,
    input wire reset_button, // Dock S1, active HIGH; CST enables internal pulldown
    input wire pressure_rx,
    input wire ctrl_rx,
    output wire ctrl_tx
);
    // Gowin supports configuration-time register initial values. No PLL needed.
    (* syn_preserve=1, async_reg="true" *) reg button_meta=0, button_sync=0;
    localparam integer CW=$clog2(RESET_HOLD_CLKS+1);
    reg [CW-1:0] reset_count=0;
    wire core_reset_n=(reset_count==RESET_HOLD_CLKS);
    always @(posedge clk) begin
        button_meta<=reset_button;
        button_sync<=button_meta;
        if (button_sync) reset_count<=0;
        else if (reset_count!=RESET_HOLD_CLKS) reset_count<=reset_count+1'b1;
    end

    // Instance/module syn_noprune + syn_preserve retain dangling consumer logic;
    // syn_keep alone is insufficient in Gowin. Keep snapshots for GAO/audio wiring.
    // Otherwise an unconnected pressure consumer could remove the entire RX path.
    (* syn_keep=1 *) wire [95:0] pressure;
    (* syn_keep=1 *) wire [15:0] pressure_seq;
    (* syn_keep=1 *) wire pressure_valid, pressure_link_alive, pressure_timeout_event;
    (* syn_keep=1 *) wire timbre, mode, mute;
    (* syn_keep=1 *) wire signed [7:0] transpose;
    (* syn_keep=1 *) wire [9:0] gain;
    (* syn_keep=1 *) wire [63:0] key_notes;
    (* syn_keep=1 *) wire [31:0] chord_counts, cfg_version;
    (* syn_keep=1 *) wire [255:0] chord_notes;
    (* syn_keep=1 *) wire cfg_commit, release_all_event, release_valid;
    (* syn_keep=1 *) wire [7:0] rearm_required;
    (* syn_keep=1 *) wire [767:0] diagnostics;
    // A real same-clock diagnostic sink accepts the release mailbox.
    // ACK means communication-layer handoff, NOT that any sound was released.
    reg [31:0] release_observed_count;
    (* syn_keep=1 *) wire [31:0] release_observed=release_observed_count;
    always @(posedge clk) begin
        if (!core_reset_n) release_observed_count<=0;
        else if (release_valid) release_observed_count<=release_observed_count+1'b1;
    end
    (* syn_noprune=1, syn_preserve=1 *) mcu_link_top #(.CLK_HZ(50000000)) link(
        .clk(clk),.reset_n(core_reset_n),.pressure_rx(pressure_rx),.ctrl_rx(ctrl_rx),.ctrl_tx(ctrl_tx),
        .cfg_ready(1'b1),.release_ready(1'b1),.keys_released(8'h00),
        .pressure(pressure),.pressure_seq(pressure_seq),.pressure_valid(pressure_valid),
        .pressure_link_alive(pressure_link_alive),.pressure_timeout_event(pressure_timeout_event),
        .source_mode(),.source_link_alive(),.source_changed(),.source_timeout_event(),
        .piano_base_note(),.piano_sequence(),.piano_pressed(),.piano_force(),
        .piano_snapshot_valid(),.piano_link_alive(),.piano_rearm_required(),.piano_diagnostics(),
        .timbre(timbre),.mode(mode),.mute(mute),.transpose(transpose),.gain(gain),
        .key_notes(key_notes),.chord_counts(chord_counts),.chord_notes(chord_notes),
        .cfg_commit(cfg_commit),.cfg_version(cfg_version),.release_all_event(release_all_event),
        .release_valid(release_valid),.rearm_required(rearm_required),.diagnostics(diagnostics));
endmodule
