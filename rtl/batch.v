module batch (
    input wire clk,
    input wire rst_n,
    
    // Input from insertion stage
    input wire insertion_ready,
    input wire [63:0] owner_programID,
    input wire has_conflict,  // get go ahead from filter to batch inclusion.
    
    // Output signals
    output reg transaction_accepted,
    output reg [63:0] inserted_programID,
    
    // Feedback signals to all stages
    output reg batch_update_valid,
    output reg [63:0] batch_update_id,
    output reg pipeline_ready,
    output reg [63:0] accepted_id
);

    // Parameters for batch configuration
    parameter MAX_BATCH_SIZE = 48;  // Max TXs per batch
    parameter BATCH_INDEX_BITS = 6;  

    // Batch storage
    reg [63:0] batch_transactions [MAX_BATCH_SIZE-1:0];  // Each entry is a 64-bit program ID
    reg [BATCH_INDEX_BITS-1:0] batch_size;  // Current number of transactions in batch

    // Pipeline state
    reg processing_transaction;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            transaction_accepted <= 1'b0;
            inserted_programID <= 64'd0;
            batch_update_valid <= 1'b0;
            batch_update_id <= 64'd0;
            pipeline_ready <= 1'b1;
            accepted_id <= 64'd0;
            batch_size <= {BATCH_INDEX_BITS{1'b0}};
            processing_transaction <= 1'b0;
        end
        else begin
            // Default values - reset all signals unless explicitly set
            transaction_accepted <= 1'b0;
            inserted_programID <= 64'd0;
            batch_update_valid <= 1'b0;
            batch_update_id <= 64'd0;
            
            if (has_conflict) begin
                // On conflict, immediately reset processing state
                processing_transaction <= 1'b0;
                pipeline_ready <= 1'b1;
                accepted_id <= 64'd0;
            end
            else if (insertion_ready && !processing_transaction && batch_size < MAX_BATCH_SIZE) begin
                processing_transaction <= 1'b1;
                pipeline_ready <= 1'b0;
                
                // Process non-conflicting transaction
                batch_transactions[batch_size] <= owner_programID;
                batch_size <= batch_size + 1'b1;
                
                // Signal successful insertion
                transaction_accepted <= 1'b1;
                inserted_programID <= owner_programID;
                accepted_id <= owner_programID;
                
                // Update filter engine
                batch_update_valid <= 1'b1;
                batch_update_id <= owner_programID;
            end
            else if (processing_transaction) begin
                // Reset processing state and allow next transaction
                processing_transaction <= 1'b0;
                pipeline_ready <= 1'b1;
                
                // Keep accepted_id stable for one more cycle if it was set
                if (transaction_accepted) begin
                    accepted_id <= inserted_programID;
                end
                else begin
                    accepted_id <= 64'd0;
                end
            end
            else begin
                // When idle, keep pipeline ready and clear accepted_id
                pipeline_ready <= 1'b1;
                accepted_id <= 64'd0;
            end
        end
    end
endmodule
