///////////
// Insertion - Accepts tx from filter engine and forwards it to batch.
///////////

module insertion (
    input wire clk,
    input wire rst_n,
    
    // Inputs from filter engine
    input wire filter_ready,
    input wire [63:0] owner_programID,
    
    // Feedback signals from batch
    input wire pipeline_ready,
    input wire [63:0] accepted_id,
    
    // Output signal
    output reg insertion_ready
);

    // Pipeline state
    reg waiting_for_acceptance;
    reg [63:0] current_transaction_id;

    // Insertion logic with pipeline feedback
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            insertion_ready <= 1'b0;
            waiting_for_acceptance <= 1'b0;
            current_transaction_id <= 64'd0;
        end
        else begin
            if (pipeline_ready) begin
                waiting_for_acceptance <= 1'b0;
                
                if (filter_ready && !waiting_for_acceptance) begin
                    insertion_ready <= 1'b1;
                    waiting_for_acceptance <= 1'b1;
                    current_transaction_id <= owner_programID;
                end
                else begin
                    insertion_ready <= 1'b0;
                end
            end
            else begin
                // Hold current state while waiting
                insertion_ready <= 1'b0;
            end
        end
    end

endmodule
