// Complete immutable frames in a bounded FIFO, plus a separate active TX frame.
module control_reply_tx #(
    parameter integer DEPTH=4
)(
    input wire clk, rst_n,
    input wire [127:0] reply,
    input wire reply_valid,
    output wire reply_ready,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready,
    output reg [31:0] reply_count
);
    localparam integer PW=(DEPTH<=1)?1:$clog2(DEPTH);
    reg [127:0] fifo[0:DEPTH-1];
    reg [PW-1:0] rd_ptr, wr_ptr;
    reg [$clog2(DEPTH+1)-1:0] count;
    reg [127:0] active;
    reg sending;
    reg [3:0] index;
    wire pop=!sending && count!=0;
    wire push=reply_valid && reply_ready;
    assign reply_ready=count<DEPTH;
    assign tx_data=active[index*8+:8];
    assign tx_valid=sending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr<=0; wr_ptr<=0; count<=0; active<=0; sending<=0; index<=0; reply_count<=0;
        end else begin
            case ({push,pop})
                2'b10: count<=count+1'b1;
                2'b01: count<=count-1'b1;
                default: count<=count;
            endcase
            if (push) begin
                fifo[wr_ptr]<=reply;
                if (wr_ptr==DEPTH-1) wr_ptr<={PW{1'b0}};
                else wr_ptr<=wr_ptr+1'b1;
            end
            if (pop) begin
                active<=fifo[rd_ptr]; sending<=1; index<=0;
                if (rd_ptr==DEPTH-1) rd_ptr<={PW{1'b0}};
                else rd_ptr<=rd_ptr+1'b1;
            end
            if (sending && tx_ready) begin
                if (index==15) begin sending<=0; reply_count<=reply_count+1'b1; end
                else index<=index+1'b1;
            end
        end
    end
endmodule
