// Rounded integer bit timing; require CLK_HZ/BAUD >= 16.
// One byte per valid pulse, consumed unconditionally by the frame parser.
module link_uart_rx #(
    parameter integer CLK_HZ=50000000, BAUD=115200
)(
    input wire clk, rst_n, rx,
    output reg [7:0] data,
    output reg valid, framing_error, break_event
);
    localparam integer BIT_CLKS=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=$clog2(BIT_CLKS+1);
    localparam integer BW=$clog2(11*BIT_CLKS+1);
    (* syn_preserve=1, async_reg="true" *) reg rx_meta, rx_sync;
    reg [2:0] state;
    reg [CW-1:0] timer;
    reg [BW-1:0] low_count;
    reg break_seen;
    reg [2:0] bit_index;
    reg [7:0] shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_meta<=1; rx_sync<=1; end
        else begin rx_meta<=rx; rx_sync<=rx_meta; end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=0; timer<=0; low_count<=0; break_seen<=0;
            bit_index<=0; shift<=0; data<=0;
            valid<=0; framing_error<=0; break_event<=0;
        end else begin
            valid<=0; framing_error<=0; break_event<=0;
            if (rx_sync) begin low_count<=0; break_seen<=0; end
            else if (!break_seen) begin
                if (low_count==11*BIT_CLKS-1) begin
                    break_event<=1; break_seen<=1;
                end else low_count<=low_count+1'b1;
            end
            case (state)
                0: if (!rx_sync) begin state<=1; timer<=BIT_CLKS/2-1; end
                1: if (timer!=0) timer<=timer-1'b1;
                   else if (rx_sync) state<=0;
                   else begin state<=2; bit_index<=0; timer<=BIT_CLKS-1; end
                2: if (timer!=0) timer<=timer-1'b1;
                   else begin
                       shift[bit_index]<=rx_sync; timer<=BIT_CLKS-1;
                       if (bit_index==7) state<=3;
                       else bit_index<=bit_index+1'b1;
                   end
                3: if (timer!=0) timer<=timer-1'b1;
                   else if (rx_sync) begin data<=shift; valid<=1; state<=0; end
                   else begin framing_error<=1; state<=4; end
                4: if (rx_sync) state<=0;
                default: state<=0;
            endcase
        end
    end
endmodule
