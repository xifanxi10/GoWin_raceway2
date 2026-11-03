`timescale 1ns/1ps

// Same clock/reset domain as mcu_link_top. ADC increases with pressure.
// Defaults are EXAMPLES: calibrate thresholds against actual sensor readings.
module pressure_keys #(
    parameter integer ON_LEVEL = 300,
    parameter integer OFF_LEVEL = 200,
    parameter integer FULL_LEVEL = 3000,
    parameter integer CONFIRM_FRAMES = 2
)(
    input wire clk, reset_n,
    input wire [95:0] pressure,
    input wire pressure_valid, pressure_link_alive,
    input wire release_valid, mute,
    input wire [7:0] rearm_required,
    output wire release_ready,
    output wire [7:0] keys_released,
    output reg [3:0] key_down,
    output reg [31:0] strength
);
    localparam integer CW = (CONFIRM_FRAMES < 2) ? 1 : $clog2(CONFIRM_FRAMES + 1);
    reg [CW-1:0] count [0:3];
    reg [11:0] peak [0:3];
    reg [3:0] armed;
    wire [11:0] adc [0:3];
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : channels
            assign adc[g] = pressure[g*12 +: 12];
            assign keys_released[g] = pressure_valid && pressure_link_alive && adc[g] <= OFF_LEVEL;
        end
    endgenerate
    // The unused four channels are not declared calibrated/released.
    assign keys_released[7:4] = 4'b0000;
    assign release_ready = reset_n;

    function [7:0] velocity_for;
        input [11:0] value;
        reg [31:0] scaled;
        reg [11:0] delta;
        // Constant reciprocal: error below one velocity step over 12-bit range.
        localparam [23:0] SCALE = (254 * 65536) / (FULL_LEVEL - ON_LEVEL);
        begin
            if (value >= FULL_LEVEL)
                velocity_for = 255;
            else if (value <= ON_LEVEL)
                velocity_for = 1;
            else begin
                delta = value - ON_LEVEL;
                scaled = delta * SCALE;
                velocity_for = 1 + (scaled >> 16);
            end
        end
    endfunction

    // synthesis translate_off
    initial begin
        if (OFF_LEVEL < 0 || OFF_LEVEL >= ON_LEVEL || ON_LEVEL >= FULL_LEVEL || FULL_LEVEL > 4095 || CONFIRM_FRAMES < 1)
            $fatal(1, "Invalid pressure calibration parameters");
    end
    // synthesis translate_on

    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key_down <= 0;
            strength <= 0;
            armed <= 0;
            for (i = 0; i < 4; i = i + 1) begin
                count[i] <= 0;
                peak[i] <= 0;
            end
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                if (!pressure_link_alive || release_valid || mute) begin
                    key_down[i] <= 0;
                    armed[i] <= 0;
                    count[i] <= 0;
                    peak[i] <= 0;
                end else if (pressure_valid) begin
                    if (adc[i] <= OFF_LEVEL) begin
                        key_down[i] <= 0;
                        armed[i] <= 1;
                        count[i] <= 0;
                        peak[i] <= 0;
                    end else if (rearm_required[i]) begin
                        key_down[i] <= 0;
                        armed[i] <= 0;
                        count[i] <= 0;
                        peak[i] <= 0;
                    end else if (!key_down[i] && armed[i]) begin
                        if (adc[i] >= ON_LEVEL) begin
                            if (adc[i] > peak[i])
                                peak[i] <= adc[i];
                            if (count[i] == CONFIRM_FRAMES - 1) begin
                                // Both become visible together; a downstream synchronous
                                // KS observes the new velocity when detecting note_on.
                                strength[i*8 +: 8] <= velocity_for(adc[i] > peak[i] ? adc[i] : peak[i]);
                                key_down[i] <= 1;
                                count[i] <= 0;
                            end else
                                count[i] <= count[i] + 1'b1;
                        end else begin
                            count[i] <= 0;
                            peak[i] <= 0;
                        end
                    end
                end
            end
        end
    end
endmodule
