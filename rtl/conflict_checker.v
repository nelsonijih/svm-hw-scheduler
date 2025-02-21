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
            if (pipeline_ready) begin
                // Pipeline is ready for new transaction
                waiting_for_acceptance <= 1'b0;
                
                if (transaction_valid && !waiting_for_acceptance) begin
                    // Forward new transaction
                    transaction_forwarded <= 1'b1;
                    waiting_for_acceptance <= 1'b1;
                    current_transaction_id <= owner_programID;
                end
                else begin
                    transaction_forwarded <= 1'b0;
                end
            end
            else begin
                // Hold current state while waiting
                transaction_forwarded <= 1'b0;
            end
        end
    end

endmodule
