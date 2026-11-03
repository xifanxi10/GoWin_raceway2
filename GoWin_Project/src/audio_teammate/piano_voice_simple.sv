`timescale 1ns/1ps
// Six additive sine partials, independent decay and velocity-dependent brightness.
// 96 kHz samples, at least 32 clk cycles/sample. No recorded PCM is used.
module piano_voice_simple #(
    parameter [31:0] SEED = 32'h13579bdf,
    parameter integer HOLD_DECAY_SHIFT = 17,
    parameter integer RELEASE_DECAY_SHIFT = 13,
    parameter integer MIN_STRIKE_AMPLITUDE = 8,
    parameter integer SILENCE_AMPLITUDE = 1,
    parameter integer VIBRATO_ENABLE = 1
)(
    input wire clk,
    input wire rst,
    input wire sample_tick,
    input wire signed [31:0] vibrato_delta,
    input wire [6:0] vibrato_note,
    output wire [31:0] base_step_out,
    input wire key_down,
    input wire [6:0] midi,
    input wire [11:0] force_value,
    output reg signed [15:0] voice,
    output wire active
);
    function automatic [31:0] phase_increment(input [6:0] note);
        integer octave;
        integer semitone;
        reg [31:0] octave_base;
        begin
            // C4..B4 phase increments at the 96 kHz PCM rate.  Higher and
            // lower octaves are exact power-of-two shifts of this table.
            octave_base = 0;
            case (note % 12)
                0: octave_base=32'd11704930;
                1: octave_base=32'd12400941;
                2: octave_base=32'd13138339;
                3: octave_base=32'd13919586;
                4: octave_base=32'd14747287;
                5: octave_base=32'd15624207;
                6: octave_base=32'd16553270;
                7: octave_base=32'd17537579;
                8: octave_base=32'd18580418;
                9: octave_base=32'd19685267;
                10: octave_base=32'd20855814;
                default: octave_base=32'd22095965;
            endcase
            octave = note / 12;
            semitone = note % 12;
            if (note < 7'd21 || note > 7'd108)
                phase_increment = 0;
            else if (octave >= 5)
                phase_increment = octave_base << (octave-5);
            else
                phase_increment = octave_base >> (5-octave);
        end
    endfunction

    reg signed [11:0] sine_rom [0:255];
    initial begin
        sine_rom[0] = 12'sd0;
        sine_rom[1] = 12'sd50;
        sine_rom[2] = 12'sd100;
        sine_rom[3] = 12'sd151;
        sine_rom[4] = 12'sd201;
        sine_rom[5] = 12'sd251;
        sine_rom[6] = 12'sd300;
        sine_rom[7] = 12'sd350;
        sine_rom[8] = 12'sd399;
        sine_rom[9] = 12'sd449;
        sine_rom[10] = 12'sd497;
        sine_rom[11] = 12'sd546;
        sine_rom[12] = 12'sd594;
        sine_rom[13] = 12'sd642;
        sine_rom[14] = 12'sd690;
        sine_rom[15] = 12'sd737;
        sine_rom[16] = 12'sd783;
        sine_rom[17] = 12'sd830;
        sine_rom[18] = 12'sd875;
        sine_rom[19] = 12'sd920;
        sine_rom[20] = 12'sd965;
        sine_rom[21] = 12'sd1009;
        sine_rom[22] = 12'sd1052;
        sine_rom[23] = 12'sd1095;
        sine_rom[24] = 12'sd1137;
        sine_rom[25] = 12'sd1179;
        sine_rom[26] = 12'sd1219;
        sine_rom[27] = 12'sd1259;
        sine_rom[28] = 12'sd1299;
        sine_rom[29] = 12'sd1337;
        sine_rom[30] = 12'sd1375;
        sine_rom[31] = 12'sd1411;
        sine_rom[32] = 12'sd1447;
        sine_rom[33] = 12'sd1483;
        sine_rom[34] = 12'sd1517;
        sine_rom[35] = 12'sd1550;
        sine_rom[36] = 12'sd1582;
        sine_rom[37] = 12'sd1614;
        sine_rom[38] = 12'sd1644;
        sine_rom[39] = 12'sd1674;
        sine_rom[40] = 12'sd1702;
        sine_rom[41] = 12'sd1729;
        sine_rom[42] = 12'sd1756;
        sine_rom[43] = 12'sd1781;
        sine_rom[44] = 12'sd1805;
        sine_rom[45] = 12'sd1828;
        sine_rom[46] = 12'sd1850;
        sine_rom[47] = 12'sd1871;
        sine_rom[48] = 12'sd1891;
        sine_rom[49] = 12'sd1910;
        sine_rom[50] = 12'sd1927;
        sine_rom[51] = 12'sd1944;
        sine_rom[52] = 12'sd1959;
        sine_rom[53] = 12'sd1973;
        sine_rom[54] = 12'sd1986;
        sine_rom[55] = 12'sd1997;
        sine_rom[56] = 12'sd2008;
        sine_rom[57] = 12'sd2017;
        sine_rom[58] = 12'sd2025;
        sine_rom[59] = 12'sd2032;
        sine_rom[60] = 12'sd2037;
        sine_rom[61] = 12'sd2041;
        sine_rom[62] = 12'sd2045;
        sine_rom[63] = 12'sd2046;
        sine_rom[64] = 12'sd2047;
        sine_rom[65] = 12'sd2046;
        sine_rom[66] = 12'sd2045;
        sine_rom[67] = 12'sd2041;
        sine_rom[68] = 12'sd2037;
        sine_rom[69] = 12'sd2032;
        sine_rom[70] = 12'sd2025;
        sine_rom[71] = 12'sd2017;
        sine_rom[72] = 12'sd2008;
        sine_rom[73] = 12'sd1997;
        sine_rom[74] = 12'sd1986;
        sine_rom[75] = 12'sd1973;
        sine_rom[76] = 12'sd1959;
        sine_rom[77] = 12'sd1944;
        sine_rom[78] = 12'sd1927;
        sine_rom[79] = 12'sd1910;
        sine_rom[80] = 12'sd1891;
        sine_rom[81] = 12'sd1871;
        sine_rom[82] = 12'sd1850;
        sine_rom[83] = 12'sd1828;
        sine_rom[84] = 12'sd1805;
        sine_rom[85] = 12'sd1781;
        sine_rom[86] = 12'sd1756;
        sine_rom[87] = 12'sd1729;
        sine_rom[88] = 12'sd1702;
        sine_rom[89] = 12'sd1674;
        sine_rom[90] = 12'sd1644;
        sine_rom[91] = 12'sd1614;
        sine_rom[92] = 12'sd1582;
        sine_rom[93] = 12'sd1550;
        sine_rom[94] = 12'sd1517;
        sine_rom[95] = 12'sd1483;
        sine_rom[96] = 12'sd1447;
        sine_rom[97] = 12'sd1411;
        sine_rom[98] = 12'sd1375;
        sine_rom[99] = 12'sd1337;
        sine_rom[100] = 12'sd1299;
        sine_rom[101] = 12'sd1259;
        sine_rom[102] = 12'sd1219;
        sine_rom[103] = 12'sd1179;
        sine_rom[104] = 12'sd1137;
        sine_rom[105] = 12'sd1095;
        sine_rom[106] = 12'sd1052;
        sine_rom[107] = 12'sd1009;
        sine_rom[108] = 12'sd965;
        sine_rom[109] = 12'sd920;
        sine_rom[110] = 12'sd875;
        sine_rom[111] = 12'sd830;
        sine_rom[112] = 12'sd783;
        sine_rom[113] = 12'sd737;
        sine_rom[114] = 12'sd690;
        sine_rom[115] = 12'sd642;
        sine_rom[116] = 12'sd594;
        sine_rom[117] = 12'sd546;
        sine_rom[118] = 12'sd497;
        sine_rom[119] = 12'sd449;
        sine_rom[120] = 12'sd399;
        sine_rom[121] = 12'sd350;
        sine_rom[122] = 12'sd300;
        sine_rom[123] = 12'sd251;
        sine_rom[124] = 12'sd201;
        sine_rom[125] = 12'sd151;
        sine_rom[126] = 12'sd100;
        sine_rom[127] = 12'sd50;
        sine_rom[128] = 12'sd0;
        sine_rom[129] = -12'sd50;
        sine_rom[130] = -12'sd100;
        sine_rom[131] = -12'sd151;
        sine_rom[132] = -12'sd201;
        sine_rom[133] = -12'sd251;
        sine_rom[134] = -12'sd300;
        sine_rom[135] = -12'sd350;
        sine_rom[136] = -12'sd399;
        sine_rom[137] = -12'sd449;
        sine_rom[138] = -12'sd497;
        sine_rom[139] = -12'sd546;
        sine_rom[140] = -12'sd594;
        sine_rom[141] = -12'sd642;
        sine_rom[142] = -12'sd690;
        sine_rom[143] = -12'sd737;
        sine_rom[144] = -12'sd783;
        sine_rom[145] = -12'sd830;
        sine_rom[146] = -12'sd875;
        sine_rom[147] = -12'sd920;
        sine_rom[148] = -12'sd965;
        sine_rom[149] = -12'sd1009;
        sine_rom[150] = -12'sd1052;
        sine_rom[151] = -12'sd1095;
        sine_rom[152] = -12'sd1137;
        sine_rom[153] = -12'sd1179;
        sine_rom[154] = -12'sd1219;
        sine_rom[155] = -12'sd1259;
        sine_rom[156] = -12'sd1299;
        sine_rom[157] = -12'sd1337;
        sine_rom[158] = -12'sd1375;
        sine_rom[159] = -12'sd1411;
        sine_rom[160] = -12'sd1447;
        sine_rom[161] = -12'sd1483;
        sine_rom[162] = -12'sd1517;
        sine_rom[163] = -12'sd1550;
        sine_rom[164] = -12'sd1582;
        sine_rom[165] = -12'sd1614;
        sine_rom[166] = -12'sd1644;
        sine_rom[167] = -12'sd1674;
        sine_rom[168] = -12'sd1702;
        sine_rom[169] = -12'sd1729;
        sine_rom[170] = -12'sd1756;
        sine_rom[171] = -12'sd1781;
        sine_rom[172] = -12'sd1805;
        sine_rom[173] = -12'sd1828;
        sine_rom[174] = -12'sd1850;
        sine_rom[175] = -12'sd1871;
        sine_rom[176] = -12'sd1891;
        sine_rom[177] = -12'sd1910;
        sine_rom[178] = -12'sd1927;
        sine_rom[179] = -12'sd1944;
        sine_rom[180] = -12'sd1959;
        sine_rom[181] = -12'sd1973;
        sine_rom[182] = -12'sd1986;
        sine_rom[183] = -12'sd1997;
        sine_rom[184] = -12'sd2008;
        sine_rom[185] = -12'sd2017;
        sine_rom[186] = -12'sd2025;
        sine_rom[187] = -12'sd2032;
        sine_rom[188] = -12'sd2037;
        sine_rom[189] = -12'sd2041;
        sine_rom[190] = -12'sd2045;
        sine_rom[191] = -12'sd2046;
        sine_rom[192] = -12'sd2047;
        sine_rom[193] = -12'sd2046;
        sine_rom[194] = -12'sd2045;
        sine_rom[195] = -12'sd2041;
        sine_rom[196] = -12'sd2037;
        sine_rom[197] = -12'sd2032;
        sine_rom[198] = -12'sd2025;
        sine_rom[199] = -12'sd2017;
        sine_rom[200] = -12'sd2008;
        sine_rom[201] = -12'sd1997;
        sine_rom[202] = -12'sd1986;
        sine_rom[203] = -12'sd1973;
        sine_rom[204] = -12'sd1959;
        sine_rom[205] = -12'sd1944;
        sine_rom[206] = -12'sd1927;
        sine_rom[207] = -12'sd1910;
        sine_rom[208] = -12'sd1891;
        sine_rom[209] = -12'sd1871;
        sine_rom[210] = -12'sd1850;
        sine_rom[211] = -12'sd1828;
        sine_rom[212] = -12'sd1805;
        sine_rom[213] = -12'sd1781;
        sine_rom[214] = -12'sd1756;
        sine_rom[215] = -12'sd1729;
        sine_rom[216] = -12'sd1702;
        sine_rom[217] = -12'sd1674;
        sine_rom[218] = -12'sd1644;
        sine_rom[219] = -12'sd1614;
        sine_rom[220] = -12'sd1582;
        sine_rom[221] = -12'sd1550;
        sine_rom[222] = -12'sd1517;
        sine_rom[223] = -12'sd1483;
        sine_rom[224] = -12'sd1447;
        sine_rom[225] = -12'sd1411;
        sine_rom[226] = -12'sd1375;
        sine_rom[227] = -12'sd1337;
        sine_rom[228] = -12'sd1299;
        sine_rom[229] = -12'sd1259;
        sine_rom[230] = -12'sd1219;
        sine_rom[231] = -12'sd1179;
        sine_rom[232] = -12'sd1137;
        sine_rom[233] = -12'sd1095;
        sine_rom[234] = -12'sd1052;
        sine_rom[235] = -12'sd1009;
        sine_rom[236] = -12'sd965;
        sine_rom[237] = -12'sd920;
        sine_rom[238] = -12'sd875;
        sine_rom[239] = -12'sd830;
        sine_rom[240] = -12'sd783;
        sine_rom[241] = -12'sd737;
        sine_rom[242] = -12'sd690;
        sine_rom[243] = -12'sd642;
        sine_rom[244] = -12'sd594;
        sine_rom[245] = -12'sd546;
        sine_rom[246] = -12'sd497;
        sine_rom[247] = -12'sd449;
        sine_rom[248] = -12'sd399;
        sine_rom[249] = -12'sd350;
        sine_rom[250] = -12'sd300;
        sine_rom[251] = -12'sd251;
        sine_rom[252] = -12'sd201;
        sine_rom[253] = -12'sd151;
        sine_rom[254] = -12'sd100;
        sine_rom[255] = -12'sd50;
    end

    // Audition profile: low-note harmonic support, gentle treble attenuation.
    // Values are captured at note-on; changing pitch while held keeps the envelope.
    function automatic [7:0] weight(input integer n, input [6:0] note);
        reg [47:0] weights;
        begin
            case (note)
                7'd21: weights = 48'h0c1426406478;
                7'd22: weights = 48'h0c1426406478;
                7'd23: weights = 48'h0c1426406478;
                7'd24: weights = 48'h0c1426406478;
                7'd25: weights = 48'h0c1426406478;
                7'd26: weights = 48'h0c1426406478;
                7'd27: weights = 48'h0c1426406478;
                7'd28: weights = 48'h0c1426406478;
                7'd29: weights = 48'h0c1426406478;
                7'd30: weights = 48'h0c1426406478;
                7'd31: weights = 48'h0c1426406478;
                7'd32: weights = 48'h0c1426406478;
                7'd33: weights = 48'h0c1426406478;
                7'd34: weights = 48'h0c1426406478;
                7'd35: weights = 48'h0c1426406478;
                7'd36: weights = 48'h0c1426406478;
                7'd37: weights = 48'h0c14253f6278;
                7'd38: weights = 48'h0c14253d6078;
                7'd39: weights = 48'h0c14243c5e78;
                7'd40: weights = 48'h0c13233b5d78;
                7'd41: weights = 48'h0c1323395b78;
                7'd42: weights = 48'h0c1322385978;
                7'd43: weights = 48'h0b1321375778;
                7'd44: weights = 48'h0b1321355578;
                7'd45: weights = 48'h0b1220345478;
                7'd46: weights = 48'h0b121f335278;
                7'd47: weights = 48'h0b121f315078;
                7'd48: weights = 48'h0b121e304e78;
                7'd49: weights = 48'h0b121d2f4c78;
                7'd50: weights = 48'h0b121d2d4a78;
                7'd51: weights = 48'h0b111c2c4878;
                7'd52: weights = 48'h0b111b2b4678;
                7'd53: weights = 48'h0b111b294478;
                7'd54: weights = 48'h0a101a284278;
                7'd55: weights = 48'h0a1019274178;
                7'd56: weights = 48'h0a1019253f78;
                7'd57: weights = 48'h0a1018243d78;
                7'd58: weights = 48'h0a1017233b78;
                7'd59: weights = 48'h0a0f17213978;
                7'd60: weights = 48'h0a0f16203778;
                7'd61: weights = 48'h0a0f16203676;
                7'd62: weights = 48'h0a0f161f3675;
                7'd63: weights = 48'h0a0e151f3574;
                7'd64: weights = 48'h0a0e151e3472;
                7'd65: weights = 48'h0a0e151e3470;
                7'd66: weights = 48'h0a0e141e336f;
                7'd67: weights = 48'h090e141d326e;
                7'd68: weights = 48'h090e141d326c;
                7'd69: weights = 48'h090e141c316a;
                7'd70: weights = 48'h090d141c3069;
                7'd71: weights = 48'h090d131b3068;
                7'd72: weights = 48'h090d131b2f66;
                7'd73: weights = 48'h090d131b2e64;
                7'd74: weights = 48'h090d121a2e63;
                7'd75: weights = 48'h080c121a2d62;
                7'd76: weights = 48'h080c12192c60;
                7'd77: weights = 48'h080c11192c5e;
                7'd78: weights = 48'h080c11182b5d;
                7'd79: weights = 48'h080c11182a5c;
                7'd80: weights = 48'h080c10182a5a;
                7'd81: weights = 48'h080c10172958;
                7'd82: weights = 48'h070b10172857;
                7'd83: weights = 48'h070b0f162856;
                7'd84: weights = 48'h070b0f162754;
                7'd85: weights = 48'h070b0f162653;
                7'd86: weights = 48'h070b0f162652;
                7'd87: weights = 48'h070a0e152651;
                7'd88: weights = 48'h070a0e152550;
                7'd89: weights = 48'h070a0e15244f;
                7'd90: weights = 48'h060a0e14244e;
                7'd91: weights = 48'h060a0e14244d;
                7'd92: weights = 48'h060a0e14234c;
                7'd93: weights = 48'h060a0e14224b;
                7'd94: weights = 48'h06090d14224a;
                7'd95: weights = 48'h06090d132249;
                7'd96: weights = 48'h06090d132148;
                7'd97: weights = 48'h06090d132148;
                7'd98: weights = 48'h06090d132148;
                7'd99: weights = 48'h06090d132148;
                7'd100: weights = 48'h06090d132148;
                7'd101: weights = 48'h06090d132148;
                7'd102: weights = 48'h06090d132148;
                7'd103: weights = 48'h06090d132148;
                7'd104: weights = 48'h06090d132148;
                7'd105: weights = 48'h06090d132148;
                7'd106: weights = 48'h06090d132148;
                7'd107: weights = 48'h06090d132148;
                7'd108: weights = 48'h06090d132148;
                default: weights = 48'h06090d132148;
            endcase
            weight = weights[n*8 +: 8];
        end
    endfunction

    function automatic [23:0] initial_level(input integer n, input [7:0] v, input [6:0] note);
        reg [31:0] level;
        begin
            level = weight(n, note) * v;
            if (n != 0) begin
                if (v < 64) level = level >> 2;
                else if (v < 128) level = level >> 1;
                else if (v < 192) level = (level >> 1) + (level >> 2);
            end
            initial_level = level << 8;
        end
    endfunction

    reg key_d;
    reg [7:0] strike_velocity;
    reg [6:0] strike_note;
    wire note_on = key_down && !key_d;
    wire [31:0] phase_step = phase_increment(midi);
    assign base_step_out = phase_step;
    wire [31:0] vibrato_step = VIBRATO_ENABLE && vibrato_note == midi ?
        phase_step + vibrato_delta : phase_step;
    wire [8:0] velocity_raw = {1'b0,force_value[11:4]} + MIN_STRIKE_AMPLITUDE;
    wire [7:0] velocity = force_value == 0 ? 8'd0 :
        (velocity_raw > 255 ? 8'd255 : velocity_raw[7:0]);
    reg [31:0] phase;
    reg [31:0] sample_phase, sample_step;
    reg [23:0] envelope [0:5];
    reg [7:0] attack;
    reg [2:0] index;
    reg [2:0] state;
    assign active = key_down || state == 6 ||
        (|envelope[0]) || (|envelope[1]) || (|envelope[2]) ||
        (|envelope[3]) || (|envelope[4]) || (|envelope[5]);

    localparam IDLE=0, LOOKUP=1, MULTIPLY=2, ACCUMULATE=3, OUTPUT=4;
    reg signed [11:0] wave_sample;
    reg partial_valid;
    reg signed [20:0] product;
    reg signed [23:0] sum;
    reg signed [32:0] output_product;
    function automatic [23:0] harmonic(input [23:0] x, input [2:0] n);
        case (n)
            0: harmonic = x;
            1: harmonic = x << 1;
            2: harmonic = (x << 1) + x;
            3: harmonic = x << 2;
            4: harmonic = (x << 2) + x;
            default: harmonic = (x << 2) + (x << 1);
        endcase
    endfunction
    function automatic [31:0] nyquist_limit(input [2:0] n);
        case (n)
            0: nyquist_limit = 32'd2147483648;
            1: nyquist_limit = 32'd1073741824;
            2: nyquist_limit = 32'd715827882;
            3: nyquist_limit = 32'd536870912;
            4: nyquist_limit = 32'd429496729;
            default: nyquist_limit = 32'd357913941;
        endcase
    endfunction
    wire [23:0] harmonic_phase = harmonic(sample_phase[31:8],index);
    wire signed [32:0] final_sample = output_product >>> 12;
    integer i;
    integer shift_amount;
    reg [23:0] loss;

    always @(posedge clk) begin
        if (rst) begin
            key_d <= 0;
            strike_velocity <= 0;
            strike_note <= 60;
            phase <= SEED;
            sample_phase <= 0;
            sample_step <= 0;
            attack <= 0;
            index <= 0;
            state <= IDLE;
            wave_sample <= 0;
            partial_valid <= 0;
            product <= 0;
            sum <= 0;
            output_product <= 0;
            voice <= 0;
            for (i=0; i<6; i=i+1)
                envelope[i] <= 0;
        end else begin
            key_d <= key_down;
            if (note_on) begin
                strike_note <= midi;
                phase <= SEED;
                attack <= 0;
                state <= 6;
                index <= 0;
                strike_velocity <= phase_step == 0 ? 8'd0 : velocity;
                voice <= 0;
            end else if (state == 6) begin
                envelope[index] <= initial_level(index, strike_velocity, strike_note);
                if (index == 5)
                    state <= IDLE;
                else
                    index <= index + 1'b1;
            end else begin
                if (sample_tick) begin
                    phase <= phase + vibrato_step;
                    sample_phase <= phase;
                    sample_step <= vibrato_step;
                    attack <= attack >= 253 ? 8'd255 : attack + 8'd2;
                    sum <= 0;
                    index <= 0;
                    state <= LOOKUP;
                end else begin
                    case (state)
                        LOOKUP: begin
                            // Suppress partials at/above Nyquist, including high MIDI notes.
                            wave_sample <= sine_rom[harmonic_phase[23:16]];
                            partial_valid <= sample_step < nyquist_limit(index);
                            state <= MULTIPLY;
                        end
                        MULTIPLY: begin
                            product <= partial_valid ? wave_sample * $signed({1'b0,envelope[index][23:16]}) : 21'sd0;
                            state <= ACCUMULATE;
                        end
                        ACCUMULATE: begin
                            sum <= sum + product;
                            if (!key_down)
                                loss = envelope[index] >> RELEASE_DECAY_SHIFT;
                            else begin
                                case (index)
                                    0,1: loss = envelope[index] >> HOLD_DECAY_SHIFT;
                                    2,3: loss = envelope[index] >> (HOLD_DECAY_SHIFT-1);
                                    default: loss = envelope[index] >> (HOLD_DECAY_SHIFT-2);
                                endcase
                                // Decay depends on time and partial, not octave.
                            end
                            if (loss == 0) loss = 1;
                            if (envelope[index] <= (SILENCE_AMPLITUDE << 8))
                                envelope[index] <= 0;
                            else
                                envelope[index] <= envelope[index] - loss;
                            if (index == 5)
                                state <= OUTPUT;
                            else begin
                                index <= index + 1'b1;
                                state <= LOOKUP;
                            end
                        end
                        OUTPUT: begin
                            output_product <= sum * $signed({1'b0,attack});
                            state <= 5;
                        end
                        5: begin
                            if (final_sample > 32767)
                                voice <= 16'sh7fff;
                            else if (final_sample < -32768)
                                voice <= 16'sh8000;
                            else
                                voice <= final_sample[15:0];
                            state <= IDLE;
                        end
                        default: state <= IDLE;
                    endcase
                end
            end
        end
    end
endmodule

// Six-cycle shift/add modulation avoids a new multiplier per voice.
module piano_vibrato #(
    parameter integer ENABLE = 1,
    parameter integer TICK_SAMPLES = 100,
    parameter integer DEPTH_SHIFT = 13,
    parameter integer DELAY_SAMPLES = 9600,
    parameter integer RAMP_SAMPLES = 400
)(
    input wire clk,
    input wire rst,
    input wire note_on,
    input wire sample_tick,
    input wire [31:0] base_step,
    output wire [31:0] modulated_step
);
    reg [7:0] lfo_phase;
    reg [$clog2(TICK_SAMPLES+1)-1:0] tick_count;
    reg [$clog2(DELAY_SAMPLES+2)-1:0] delay_count;
    reg [$clog2(RAMP_SAMPLES+1)-1:0] ramp_count;
    reg [5:0] depth;
    reg signed [8:0] triangle;
    wire negative = triangle < 0;
    wire [8:0] magnitude = negative ? -triangle : triangle;
    wire [5:0] amount = magnitude > depth ? depth : magnitude[5:0];
    reg [5:0] multiplier;
    reg [31:0] term, sum, offset, captured_base, offset_base;
    reg sign_work, sign_offset;
    reg [2:0] cycles;
    wire [31:0] next_sum = sum + (multiplier[0] ? term : 32'd0);
    // A MIDI change invalidates the previous note's offset immediately.
    wire valid_offset = ENABLE && base_step == offset_base;
    assign modulated_step = !valid_offset ? base_step :
        (sign_offset ? base_step-offset : base_step+offset);
    always @* begin
        if (lfo_phase < 48)
            triangle = $signed({1'b0,lfo_phase});
        else if (lfo_phase < 144)
            triangle = 9'sd96 - $signed({1'b0,lfo_phase});
        else
            triangle = $signed({1'b0,lfo_phase}) - 9'sd192;
    end
    always @(posedge clk) begin
        if (rst || note_on) begin
            lfo_phase <= 0;
            tick_count <= 0;
            delay_count <= 0;
            ramp_count <= 0;
            depth <= 0;
            multiplier <= 0;
            term <= 0;
            sum <= 0;
            offset <= 0;
            captured_base <= 0;
            offset_base <= 0;
            sign_work <= 0;
            sign_offset <= 0;
            cycles <= 0;
        end else if (sample_tick) begin
            if (ENABLE) begin
                if (tick_count == TICK_SAMPLES-1) begin
                    tick_count <= 0;
                    lfo_phase <= lfo_phase == 191 ? 0 : lfo_phase+1'b1;
                end else
                    tick_count <= tick_count+1'b1;
                if (delay_count < DELAY_SAMPLES)
                    delay_count <= delay_count+1'b1;
                else if (depth < 48) begin
                    if (ramp_count == RAMP_SAMPLES-1) begin
                        ramp_count <= 0;
                        depth <= depth+1'b1;
                    end else
                        ramp_count <= ramp_count+1'b1;
                end
            end
            captured_base <= base_step;
            multiplier <= ENABLE ? amount : 0;
            term <= base_step >> DEPTH_SHIFT;
            sum <= 0;
            sign_work <= negative;
            cycles <= 6;
        end else if (cycles != 0) begin
            sum <= next_sum;
            multiplier <= multiplier >> 1;
            term <= term << 1;
            cycles <= cycles-1'b1;
            if (cycles == 1) begin
                offset <= next_sum;
                offset_base <= captured_base;
                sign_offset <= sign_work;
            end
        end
    end
endmodule

module piano_vibrato_offset #(
    parameter integer ENABLE = 1,
    parameter integer DEPTH_SHIFT = 13
)(
    input wire clk,
    input wire rst,
    input wire sample_tick,
    input wire [31:0] base_step,
    input wire [6:0] midi,
    input wire signed [6:0] lfo,
    output wire [31:0] modulated_step
);
    // Supported MIDI 21..108 has phase_step < 2^28 at 96kHz.
    localparam integer OFFSET_WIDTH = 34-DEPTH_SHIFT;
    reg [OFFSET_WIDTH-1:0] term, accumulator;
    reg [5:0] multiplier;
    reg [2:0] cycles;
    reg negative, valid;
    reg [6:0] work_midi;
    wire [OFFSET_WIDTH-1:0] total = accumulator + (multiplier[0] ? term : {OFFSET_WIDTH{1'b0}});
    assign modulated_step = !ENABLE || !valid || cycles != 0 || work_midi != midi ? base_step :
        (negative ? base_step-accumulator : base_step+accumulator);
    always @(posedge clk) begin
        if (rst) begin
            term <= 0;
            accumulator <= 0;

            multiplier <= 0;
            cycles <= 0;
            negative <= 0;

            valid <= 0;
            work_midi <= 0;

        end else if (sample_tick) begin
            term <= base_step >> DEPTH_SHIFT;
            accumulator <= 0;
            multiplier <= ENABLE ? (lfo < 0 ? -lfo : lfo) : 0;
            negative <= lfo < 0;
            work_midi <= midi;
            cycles <= 6;
        end else if (cycles != 0) begin
            accumulator <= total;
            term <= term << 1;
            multiplier <= multiplier >> 1;
            cycles <= cycles-1'b1;
            if (cycles == 1) begin



                valid <= 1;
            end
        end
    end
endmodule
