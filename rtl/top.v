module top (
    input wire clk,
    input wire rst_n,
    
    // Transaction inputs
    input wire [63:0] owner_programID,
    input wire [1024*64-1:0] read_dependencies,
    input wire [1024*64-1:0] write_dependencies,
    input wire transaction_valid,
    
    // Output signals
    output wire transaction_accepted,
    output wire [63:0] inserted_programID,
    output wire has_conflict,
    output wire [63:0] conflicting_id
);

    // Internal signals between stages
    wire transaction_forwarded;    // From conflict_checker to filter_engine
    wire filter_ready;            // From filter_engine to insertion
    wire insertion_ready;         // From insertion to batch
    wire batch_update_valid;      // From batch to filter_engine
    wire [63:0] batch_update_id;  // From batch to filter_engine
    wire filter_has_conflict;     // From filter_engine to conflict_checker and top
    wire [63:0] filter_conflicting_id; // From filter_engine to conflict_checker and top
    
    // Feedback signals from batch to all stages
    wire pipeline_ready;          // Indicates pipeline ready for next transaction
    wire [63:0] accepted_id;      // ID of accepted transaction
    
    // Stage 1: Conflict Checker
    conflict_checker conflict_check_stage (
        .clk(clk),
        .rst_n(rst_n),
        .owner_programID(owner_programID),
        .transaction_valid(transaction_valid),
        .read_dependencies(read_dependencies),
        .write_dependencies(write_dependencies),
        .pipeline_ready(pipeline_ready),
        .accepted_id(accepted_id),
        .has_conflict(filter_has_conflict),
        .conflicting_id(filter_conflicting_id),
        .transaction_forwarded(transaction_forwarded)
    );

    // Stage 2: Filter Engine 
    filter_engine filter_stage (
        .clk(clk),
        .rst_n(rst_n),
        .transaction_forwarded(transaction_forwarded),
        .owner_programID(owner_programID),
        .read_dependencies(read_dependencies),
        .write_dependencies(write_dependencies),
        .batch_update_valid(batch_update_valid),
        .batch_update_id(batch_update_id),
        .pipeline_ready(pipeline_ready),
        .accepted_id(accepted_id),
        .filter_ready(filter_ready),
        .has_conflict(filter_has_conflict),
        .conflicting_id(filter_conflicting_id)
    );

    // Stage 3: Insertion Logic (now with feedback)
    insertion insertion_stage (
        .clk(clk),
        .rst_n(rst_n),
        .filter_ready(filter_ready),
        .owner_programID(owner_programID),
        .pipeline_ready(pipeline_ready),
        .accepted_id(accepted_id),
        .insertion_ready(insertion_ready)
    );

    // Stage 4: Batch Storage (now generates feedback)
    batch batch_stage (
        .clk(clk),
        .rst_n(rst_n),
        .insertion_ready(insertion_ready),
        .owner_programID(owner_programID),
        .has_conflict(filter_has_conflict),  // Connect has_conflict signal
        .transaction_accepted(transaction_accepted),
        .inserted_programID(inserted_programID),
        .batch_update_valid(batch_update_valid),
        .batch_update_id(batch_update_id),
        .pipeline_ready(pipeline_ready),
        .accepted_id(accepted_id)
    );

    // Connect top-level outputs
    assign has_conflict = filter_has_conflict;
    assign conflicting_id = filter_conflicting_id;

endmodule
