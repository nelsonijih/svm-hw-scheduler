///////
// Conflict Checker - responsible for forwarding tx to a particular batchID's filter engine
// TODO: later, could iterate over all the batchIDs that the HW resources / design timing allows.
//////
module conflict_checker (
    input wire clk,
    input wire rst_n,
    
    // Transaction inputs
    input wire [63:0] owner_programID,
    input wire transaction_valid,
    input wire [1024*64-1:0] read_dependencies,
    input wire [1024*64-1:0] write_dependencies,
    
    // Feedback signals from batch
    input wire pipeline_ready,
    input wire [63:0] accepted_id,
    input wire has_conflict,  // From filter_engine
    input wire [63:0] conflicting_id,
    
    // Output signal
    output reg transaction_forwarded
);

    // Pipeline state
    reg waiting_for_acceptance;
    reg [63:0] current_transaction_id;

    // Forward logic with pipeline feedback
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            transaction_forwarded <= 1'b0;
            waiting_for_acceptance <= 1'b0;
            current_transaction_id <= 64'd0;
        end
        else begin
            // Default state
            transaction_forwarded <= 1'b0;
            
            if (waiting_for_acceptance) begin
                // Clear waiting state if transaction accepted or conflict detected
                if ((accepted_id == current_transaction_id) || has_conflict) begin
                    waiting_for_acceptance <= 1'b0;
                end
            end
            else if (pipeline_ready && transaction_valid) begin
                // Only forward new transaction when we get a valid transaction
                transaction_forwarded <= 1'b1;
                waiting_for_acceptance <= 1'b1;
                current_transaction_id <= owner_programID;
            end
        end
    end

endmodule
