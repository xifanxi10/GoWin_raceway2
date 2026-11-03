module link_uart_tx #(
    parameter integer CLK_HZ=50000000, BAUD=115200
)(
    input wire clk, rst_n,
    input wire [7:0] data,
    input wire valid,
    output wire ready,
    output reg tx
);
    localparam integer BIT_CLKS=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer CW=$clog2(BIT_CLKS+1);
    reg [CW-1:0] timer;
    reg [9:0] shift;
    reg [3:0] bits_left;
    assign ready=(bits_left==0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin timer<=0; shift<=10'h3ff; bits_left<=0; tx<=1; end
        else if (ready) begin
            tx<=1;
            if (valid) begin
                shift<={1'b1,data,1'b0}; tx<=0;
                bits_left<=10; timer<=BIT_CLKS-1;
            end
        end else if (timer!=0) timer<=timer-1'b1;
        else begin
            timer<=BIT_CLKS-1; shift<={1'b1,shift[9:1]};
            tx<=shift[1]; bits_left<=bits_left-1'b1;
        end
    end
endmodule
