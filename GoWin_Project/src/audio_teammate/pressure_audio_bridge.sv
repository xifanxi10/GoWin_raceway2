// Atomic latest-state mailbox; source holds payload until acknowledged.
// Both domains share reset assertion, with synchronous release in each domain.
module pressure_audio_bridge #(
    parameter integer WIDTH=36
) (
    input wire src_clk, dst_clk, reset_async,
    input wire [WIDTH-1:0] src_data,
    output reg [WIDTH-1:0] dst_data
);
    (* async_reg="true" *) reg [1:0] src_reset, dst_reset;
    (* async_reg="true" *) reg [1:0] req_sync, ack_sync;
    (* syn_keep=1 *) reg [WIDTH-1:0] payload;
    reg request, ack;
    always @(posedge src_clk or posedge reset_async)
        if (reset_async) src_reset <= 3;
        else src_reset <= {src_reset[0], 1'b0};
    always @(posedge dst_clk or posedge reset_async)
        if (reset_async) dst_reset <= 3;
        else dst_reset <= {dst_reset[0], 1'b0};
    always @(posedge src_clk or posedge src_reset[1]) begin
        if (src_reset[1]) begin
            payload <= 0; request <= 0; ack_sync <= 0;
        end else begin
            ack_sync <= {ack_sync[0], ack};
            if (request == ack_sync[1] && src_data != payload) begin
                payload <= src_data;
                request <= ~request;
            end
        end
    end
    always @(posedge dst_clk or posedge dst_reset[1]) begin
        if (dst_reset[1]) begin
            dst_data <= 0; req_sync <= 0; ack <= 0;
        end else begin
            req_sync <= {req_sync[0], request};
            if (req_sync[1] != ack) begin
                dst_data <= payload;
                ack <= req_sync[1];
            end
        end
    end
endmodule
