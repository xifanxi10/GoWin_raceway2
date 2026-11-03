`timescale 1ns/1ps

// 96 kHz KS voice, scheduled on the audio master clock (256 clocks/sample).
// Fixed 4096-word ring; variable Q12.8 read delay; sequential synchronous reads.
module ks_voice #(
    parameter integer ATTACK_SAMPLES = 480,
    parameter integer DECAY_SAMPLES = 7680,
    parameter integer SUSTAIN_LEVEL = 39322,
    parameter integer RELEASE_SAMPLES = 19200,
    parameter integer GLIDE_STEP = 16,
    parameter [31:0] SEED = 32'h12345678
)(
    input wire clk, rst, sample_tick, key_down,
    input wire [6:0] midi,
    input wire [7:0] strength,
    input wire [23:0] gain_down, gain_rise,
    output reg signed [15:0] voice,
    output wire active
);
    function [19:0] delay_for_midi;
        input [6:0] note;
        begin
            case (note)
                7'd21: delay_for_midi = 20'd893545;
                7'd22: delay_for_midi = 20'd843387;
                7'd23: delay_for_midi = 20'd796044;
                7'd24: delay_for_midi = 20'd751358;
                7'd25: delay_for_midi = 20'd709181;
                7'd26: delay_for_midi = 20'd669370;
                7'd27: delay_for_midi = 20'd631794;
                7'd28: delay_for_midi = 20'd596327;
                7'd29: delay_for_midi = 20'd562851;
                7'd30: delay_for_midi = 20'd531253;
                7'd31: delay_for_midi = 20'd501429;
                7'd32: delay_for_midi = 20'd473279;
                7'd33: delay_for_midi = 20'd446708;
                7'd34: delay_for_midi = 20'd421629;
                7'd35: delay_for_midi = 20'd397958;
                7'd36: delay_for_midi = 20'd375615;
                7'd37: delay_for_midi = 20'd354526;
                7'd38: delay_for_midi = 20'd334621;
                7'd39: delay_for_midi = 20'd315833;
                7'd40: delay_for_midi = 20'd298099;
                7'd41: delay_for_midi = 20'd281361;
                7'd42: delay_for_midi = 20'd265562;
                7'd43: delay_for_midi = 20'd250650;
                7'd44: delay_for_midi = 20'd236575;
                7'd45: delay_for_midi = 20'd223290;
                7'd46: delay_for_midi = 20'd210751;
                7'd47: delay_for_midi = 20'd198915;
                7'd48: delay_for_midi = 20'd187744;
                7'd49: delay_for_midi = 20'd177199;
                7'd50: delay_for_midi = 20'd167247;
                7'd51: delay_for_midi = 20'd157853;
                7'd52: delay_for_midi = 20'd148986;
                7'd53: delay_for_midi = 20'd140617;
                7'd54: delay_for_midi = 20'd132717;
                7'd55: delay_for_midi = 20'd125261;
                7'd56: delay_for_midi = 20'd118224;
                7'd57: delay_for_midi = 20'd111581;
                7'd58: delay_for_midi = 20'd105311;
                7'd59: delay_for_midi = 20'd99393;
                7'd60: delay_for_midi = 20'd93808;
                7'd61: delay_for_midi = 20'd88536;
                7'd62: delay_for_midi = 20'd83559;
                7'd63: delay_for_midi = 20'd78862;
                7'd64: delay_for_midi = 20'd74429;
                7'd65: delay_for_midi = 20'd70244;
                7'd66: delay_for_midi = 20'd66295;
                7'd67: delay_for_midi = 20'd62567;
                7'd68: delay_for_midi = 20'd59048;
                7'd69: delay_for_midi = 20'd55727;
                7'd70: delay_for_midi = 20'd52592;
                7'd71: delay_for_midi = 20'd49633;
                7'd72: delay_for_midi = 20'd46840;
                7'd73: delay_for_midi = 20'd44204;
                7'd74: delay_for_midi = 20'd41716;
                7'd75: delay_for_midi = 20'd39367;
                7'd76: delay_for_midi = 20'd37150;
                7'd77: delay_for_midi = 20'd35058;
                7'd78: delay_for_midi = 20'd33083;
                7'd79: delay_for_midi = 20'd31219;
                7'd80: delay_for_midi = 20'd29460;
                7'd81: delay_for_midi = 20'd27799;
                7'd82: delay_for_midi = 20'd26232;
                7'd83: delay_for_midi = 20'd24752;
                7'd84: delay_for_midi = 20'd23356;
                7'd85: delay_for_midi = 20'd22038;
                7'd86: delay_for_midi = 20'd20794;
                7'd87: delay_for_midi = 20'd19620;
                7'd88: delay_for_midi = 20'd18511;
                7'd89: delay_for_midi = 20'd17465;
                7'd90: delay_for_midi = 20'd16478;
                7'd91: delay_for_midi = 20'd15546;
                7'd92: delay_for_midi = 20'd14666;
                7'd93: delay_for_midi = 20'd13836;
                7'd94: delay_for_midi = 20'd13052;
                7'd95: delay_for_midi = 20'd12312;
                7'd96: delay_for_midi = 20'd11614;
                7'd97: delay_for_midi = 20'd10955;
                7'd98: delay_for_midi = 20'd10333;
                7'd99: delay_for_midi = 20'd9746;
                7'd100: delay_for_midi = 20'd9192;
                7'd101: delay_for_midi = 20'd8669;
                7'd102: delay_for_midi = 20'd8175;
                7'd103: delay_for_midi = 20'd7709;
                7'd104: delay_for_midi = 20'd7269;
                7'd105: delay_for_midi = 20'd6854;
                7'd106: delay_for_midi = 20'd6462;
                7'd107: delay_for_midi = 20'd6092;
                7'd108: delay_for_midi = 20'd5743;
                default: delay_for_midi = 0;
            endcase
        end
    endfunction

    localparam IDLE = 0, FILL = 1, WAIT_SAMPLE = 2, READ_A = 3, READ_B = 4,
               INTERPOLATE = 5, FILTER = 6, MULTIPLY = 7, WRITE = 8, PRODUCTS = 9;

    reg [3:0] state;
    reg key_d;
    wire note_on = key_down && !key_d;
    wire [19:0] target_delay = delay_for_midi(midi);
    reg [19:0] delay_q;
    reg [11:0] wr_ptr, fill_ptr, read_addr;
    reg [7:0] fraction, velocity;
    reg [31:0] noise;
    (* syn_ramstyle = "block_ram" *) reg signed [15:0] ring [0:4095];
    reg signed [15:0] rd_data, sample_a, sample_b, previous;
    reg signed [15:0] interpolated;
    reg signed [16:0] average;
    reg [23:0] gain_q;
    reg signed [40:0] feedback_product;
    reg signed [33:0] envelope_product;
    wire [16:0] envelope;
    wire env_active;
    wire valid_note = (target_delay != 0 && strength != 0);
    wire [23:0] gain_now = key_down ? gain_down : gain_rise;
    wire signed [24:0] excitation_product = $signed(noise[31:16]) * $signed({1'b0, velocity});

    // Excitation is generated in HDL, not sampled instrument audio.
    wire signed [15:0] excitation = (velocity == 255) ? $signed(noise[31:16]) : (excitation_product >>> 8);
    wire [8:0] weight_a = 9'd256 - {1'b0, fraction};
    wire signed [25:0] interpolation_sum =
        $signed(sample_a) * $signed({1'b0, weight_a}) +
        $signed(sample_b) * $signed({2'b00, fraction});
    wire signed [16:0] filter_sum =
        $signed({interpolated[15], interpolated}) + $signed({previous[15], previous});
    wire [19:0] next_delay = (target_delay == 0) ? delay_q :
        (target_delay > delay_q) ?
            ((target_delay - delay_q > GLIDE_STEP) ? delay_q + GLIDE_STEP : target_delay) :
            ((delay_q - target_delay > GLIDE_STEP) ? delay_q - GLIDE_STEP : target_delay);

    adsr_envelope #(.ATTACK_SAMPLES(ATTACK_SAMPLES),
        .DECAY_SAMPLES(DECAY_SAMPLES),
        .SUSTAIN_LEVEL(SUSTAIN_LEVEL),
        .RELEASE_SAMPLES(RELEASE_SAMPLES)) envelope_unit (.clk(clk),
        .rst(rst),
        .tick(sample_tick),
        .gate(key_down),
        .start(note_on && valid_note),
        .kill(note_on && !valid_note),
        .level(envelope),
        .active(env_active));

    assign active = (state != IDLE);

    // No reset on RAM or read register, so Vivado can infer block RAM.
    // Every address is initialized before enabling the feedback loop.
    wire ram_we = !rst && !note_on && (state == FILL || state == WRITE);
    wire [11:0] ram_write_addr = (state == FILL) ? fill_ptr : wr_ptr;
    wire signed [15:0] ram_write_data = (state == FILL) ? excitation : (feedback_product >>> 23);

    always @(posedge clk) begin
        rd_data <= ring[read_addr];
        if (ram_we)
            ring[ram_write_addr] <= ram_write_data;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            key_d <= 0;
            voice <= 0;
            delay_q <= 0;
            wr_ptr <= 0;
            fill_ptr <= 0;
            read_addr <= 0;
            fraction <= 0;
            velocity <= 0;
            noise <= SEED;
            previous <= 0;
            sample_a <= 0;
            sample_b <= 0;
            interpolated <= 0;
            average <= 0;
            gain_q <= 0;
            feedback_product <= 0;
            envelope_product <= 0;
        end else begin
            key_d <= key_down;
            if (note_on) begin
                voice <= 0;
                previous <= 0;
                wr_ptr <= 0;
                fill_ptr <= 0;
                delay_q <= target_delay;
                velocity <= strength;
                state <= valid_note ? FILL : IDLE;
            end else
                case (state)
                    IDLE: voice <= 0;

                    FILL: begin
                        noise <= {noise[30:0], noise[31] ^ noise[21] ^ noise[1] ^ noise[0]};
                        fill_ptr <= fill_ptr + 1'b1;
                        if (fill_ptr == 4095)
                            state <= WAIT_SAMPLE;
                    end

                    WAIT_SAMPLE:
                        if (sample_tick) begin
                            if (!env_active) begin
                                state <= IDLE;
                                voice <= 0;
                            end else begin
                                delay_q <= next_delay;
                                read_addr <= wr_ptr - next_delay[19:8];
                                fraction <= next_delay[7:0];
                                gain_q <= gain_now[23] ? 24'h7fffff : gain_now;
                                state <= READ_A;
                            end
                        end

                    READ_A: begin
                        read_addr <= read_addr - 1'b1;
                        state <= READ_B;
                    end

                    READ_B: begin
                        sample_a <= rd_data;
                        state <= INTERPOLATE;
                    end

                    INTERPOLATE: begin
                        sample_b <= rd_data;
                        state <= FILTER;
                    end

                    FILTER: begin
                        interpolated <= interpolation_sum >>> 8;
                        state <= MULTIPLY;
                    end

                    MULTIPLY: begin
                        average <= filter_sum >>> 1;
                        previous <= interpolated;
                        // Products are registered on the following cycle.
                        state <= PRODUCTS;
                    end

                    PRODUCTS: begin
                        feedback_product <= average * $signed({1'b0, gain_q});
                        envelope_product <= interpolated * $signed({1'b0, envelope});
                        state <= WRITE;
                    end

                    WRITE: begin
                        voice <= envelope_product >>> 16;
                        wr_ptr <= wr_ptr + 1'b1;
                        state <= WAIT_SAMPLE;
                    end

                    default: state <= IDLE;
                endcase
        end
    end
endmodule

// Q0.16 envelope with exact full scale represented by 65536.
module adsr_envelope #(
    parameter integer ATTACK_SAMPLES = 480, DECAY_SAMPLES = 7680,
    SUSTAIN_LEVEL = 39322, RELEASE_SAMPLES = 19200
)(
    input wire clk, rst, tick, gate, start, kill,
    output reg [16:0] level,
    output wire active
);
    localparam OFF = 0, ATTACK = 1, DECAY = 2, SUSTAIN = 3, RELEASE = 4;

    // Q16.16 accumulator preserves long times without coarse integer steps.
    localparam [63:0] FULL = 64'd4294967296;
    localparam [63:0] SUS = 64'd65536 * SUSTAIN_LEVEL;
    localparam [63:0] A_STEP =
        (FULL + ((ATTACK_SAMPLES > 0) ? ATTACK_SAMPLES : 1) - 1) / ((ATTACK_SAMPLES > 0) ? ATTACK_SAMPLES : 1);
    localparam [63:0] D_STEP =
        (FULL - SUS + ((DECAY_SAMPLES > 0) ? DECAY_SAMPLES : 1) - 1) / ((DECAY_SAMPLES > 0) ? DECAY_SAMPLES : 1);

    reg [2:0] stage;
    reg [32:0] accumulator, release_step;

    assign active = (stage != OFF);

    always @* level = accumulator[32:16];

    always @(posedge clk) begin
        if (rst || kill) begin
            stage <= OFF;
            accumulator <= 0;
            release_step <= 0;
        end else if (start) begin
            stage <= ATTACK;
            accumulator <= 0;
        end else if (tick) begin
            if (!gate && stage != OFF && stage != RELEASE) begin
                if (RELEASE_SAMPLES == 0 || accumulator == 0) begin
                    stage <= OFF;
                    accumulator <= 0;
                end else begin
                    release_step <=
                        ({1'b0, accumulator} + RELEASE_SAMPLES - 1) / ((RELEASE_SAMPLES > 0) ? RELEASE_SAMPLES : 1);
                    stage <= RELEASE;
                end
            end else
                case (stage)
                    OFF: accumulator <= 0;

                    ATTACK:
                        if (ATTACK_SAMPLES == 0 || accumulator + A_STEP >= FULL) begin
                            accumulator <= FULL;
                            stage <= DECAY;
                        end else
                            accumulator <= accumulator + A_STEP;

                    DECAY:
                        if (DECAY_SAMPLES == 0 || accumulator <= SUS + D_STEP) begin
                            accumulator <= SUS;
                            stage <= SUSTAIN;
                        end else
                            accumulator <= accumulator - D_STEP;

                    SUSTAIN: accumulator <= SUS;

                    RELEASE:
                        if (accumulator <= release_step) begin
                            accumulator <= 0;
                            stage <= OFF;
                        end else
                            accumulator <= accumulator - release_step;

                    default: begin
                        accumulator <= 0;
                        stage <= OFF;
                    end
                endcase
        end
    end
endmodule
