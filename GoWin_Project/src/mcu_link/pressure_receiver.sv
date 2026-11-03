module pressure_receiver #(
    parameter integer CLK_HZ=50000000, TIMEOUT_MS=20
)(
    input wire clk, rst_n,
    input wire [175:0] frame,
    input wire frame_valid,
    output reg [95:0] pressure,
    output reg [15:0] pressure_seq,
    output reg pressure_valid, link_alive, timeout_event,
    output reg [31:0] good_count, range_error_count,
    output reg [31:0] duplicate_seq_count, discontinuity_count, timeout_count
);
    localparam integer TIMEOUT_CLKS=(CLK_HZ/1000)*TIMEOUT_MS;
    reg [$clog2(TIMEOUT_CLKS+1)-1:0] age;
    reg have_seq;
    reg range_ok;
    integer i;
    always @* begin
        range_ok=1;
        for (integer k=0;k<8;k=k+1)
            if (frame[(5+2*k)*8+4+:4]!=0) range_ok=0;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pressure<=0; pressure_seq<=0; pressure_valid<=0; link_alive<=0;
            timeout_event<=0; age<=0; have_seq<=0;
            good_count<=0; range_error_count<=0; duplicate_seq_count<=0;
            discontinuity_count<=0; timeout_count<=0;
        end else begin
            pressure_valid<=0; timeout_event<=0;
            if (link_alive) begin
                if (age==TIMEOUT_CLKS-1) begin
                    link_alive<=0; timeout_event<=1; timeout_count<=timeout_count+1'b1;
                end else age<=age+1'b1;
            end
            if (frame_valid) begin
                if (!range_ok) range_error_count<=range_error_count+1'b1;
                else begin
                    for (i=0;i<8;i=i+1) pressure[i*12+:12]<=frame[(4+2*i)*8+:12];
                    pressure_seq<=frame[16+:16]; pressure_valid<=1;
                    good_count<=good_count+1'b1; link_alive<=1; age<=0;
                    // A valid frame exactly at the deadline takes precedence.
                    timeout_event<=0;
                    if (link_alive && age==TIMEOUT_CLKS-1) timeout_count<=timeout_count;
                    if (have_seq) begin
                        if (frame[16+:16]==pressure_seq) duplicate_seq_count<=duplicate_seq_count+1'b1;
                        else if (frame[16+:16]!=(pressure_seq+16'd1))
                            discontinuity_count<=discontinuity_count+1'b1;
                    end
                    have_seq<=1;
                end
            end
        end
    end
endmodule
