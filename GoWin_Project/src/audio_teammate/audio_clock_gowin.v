`timescale 1ns/1ps

// 50 MHz * 29 / 59 = 24.576271186 MHz, same ratio as the Vivado version.
// VCO = 725 MHz; sample rate = 96001.059 Hz (+11.035 ppm).
module audio_clock_gowin (
    input wire sys_clk, rst_n,
    output wire audio_clk, audio_rst
);
    wire locked;

    PLLA #(.FCLKIN("50"),
        .IDIV_SEL(1),
        .FBDIV_SEL(1),
        .MDIV_SEL(14),
        .MDIV_FRAC_SEL(4),
        .ODIV0_SEL(29),
        .ODIV0_FRAC_SEL(4),
        .CLKFB_SEL("INTERNAL"),
        .CLKOUT0_EN("TRUE")) pll (.CLKIN(sys_clk),
        .CLKOUT0(audio_clk),
        .LOCK(locked),
        .CLKFB(1'b0),
        .RESET(!rst_n),
        .PLLPWD(1'b0),
        .RESET_I(1'b0),
        .RESET_O(1'b0),
        .PSSEL(3'b0),
        .PSDIR(1'b0),
        .PSPULSE(1'b0),
        .SSCPOL(1'b0),
        .SSCON(1'b0),
        .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0),
        .MDCLK(1'b0),
        .MDOPC(2'b0),
        .MDAINC(1'b0),
        .MDWDI(8'b0));

    wire reset_async = !rst_n || !locked;
    reg [2:0] reset_pipe;

    always @(posedge audio_clk or posedge reset_async) begin
        if (reset_async)
            reset_pipe <= 3'b111;
        else
            reset_pipe <= {reset_pipe[1:0], 1'b0};
    end

    assign audio_rst = reset_pipe[2];
endmodule
