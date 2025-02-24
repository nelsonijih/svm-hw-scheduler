////////////
// Filter Engine - responsible for conflict detection and keeping track of a particular 
// batch's read/write deps table
// TODO: implement optmized version of dep checking using hashmaps/bitmaps.
////////////

module filter_engine (
    input wire clk,
    input wire rst_n,
    
    // Inputs from conflict checker
    input wire transaction_forwarded,
    input wire [63:0] owner_programID,
    input wire [1024*64-1:0] read_dependencies,
    input wire [1024*64-1:0] write_dependencies,
    
    // Inputs from batch for table updates
    input wire batch_update_valid,
    input wire [63:0] batch_update_id,
    
    // Feedback signals from batch
    input wire pipeline_ready,
    input wire [63:0] accepted_id,
    
    // Output signals
    output reg filter_ready,
    output reg has_conflict,
    output reg [63:0] conflicting_id
);

    // Constants
    parameter MAX_TRANSACTIONS = 48;
    parameter DEPS_PER_TRANSACTION = 1024;
    parameter TABLE_SIZE = MAX_TRANSACTIONS * DEPS_PER_TRANSACTION;
    parameter TABLE_INDEX_BITS = 16;  // table_size
    parameter ACCOUNT_ID_WIDTH = 64;  // Width of account/program IDs

    // Synthesis-friendly constants for loops
    localparam MAX_TX_DEPENDENCIES = DEPS_PER_TRANSACTION;
    localparam MAX_BATCH_TX = MAX_TRANSACTIONS;
    localparam TOTAL_TABLE_SIZE = MAX_BATCH_TX * MAX_TX_DEPENDENCIES;

    // Batch Dependency tables for all tx in the batch
    reg [63:0] read_dependency_table [TOTAL_TABLE_SIZE-1:0];   // Table for MAX_TRANSACTIONS * DEPS_PER_TRANSACTION each
    reg [63:0] write_dependency_table [TOTAL_TABLE_SIZE-1:0];  // Table for MAX_TRANSACTIONS * DEPS_PER_TRANSACTION each
    reg [63:0] owner_table [TOTAL_TABLE_SIZE-1:0];            // Store owner ID for each dependency
    reg [TABLE_INDEX_BITS-1:0] table_size;    // Current size of tables - keep track of how much space we have used.
    
    // Pipeline state
    reg waiting_for_acceptance;
    reg [63:0] current_transaction_id;   // Store current transaction's ID
    reg [1024*64-1:0] current_read_deps;   // Store current transaction's dependencies
    reg [1024*64-1:0] current_write_deps;  // Store current transaction's dependencies
    
    // Temporary variables for dependency checking
    integer i, j;

    // Table management and dependency checking logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            table_size <= 16'd0;
            waiting_for_acceptance <= 1'b0;
            current_transaction_id <= 64'd0;
            current_read_deps <= 0;
            current_write_deps <= 0;
            filter_ready <= 1'b0;
            has_conflict <= 1'b0;
            conflicting_id <= 64'd0;
            for (i = 0; i < TOTAL_TABLE_SIZE; i = i + 1) begin
                read_dependency_table[i] <= 64'd0;
                write_dependency_table[i] <= 64'd0;
                owner_table[i] <= 64'd0;
            end
        end
        else begin
            // Default values
            filter_ready <= 1'b0;
            
            if (transaction_forwarded && pipeline_ready) begin
                // Store the dependencies for this transaction
                current_transaction_id <= owner_programID;
                current_read_deps <= read_dependencies;
                current_write_deps <= write_dependencies;
                waiting_for_acceptance <= 1'b1;
                
                // Clear conflict flag before checking
                has_conflict <= 1'b0;
                conflicting_id <= 64'd0;
                
                // Check for conflicts
                for (i = 0; i < MAX_TX_DEPENDENCIES; i = i + 1) begin
                    if (read_dependencies[i*ACCOUNT_ID_WIDTH +: ACCOUNT_ID_WIDTH] != 0 || 
                        write_dependencies[i*ACCOUNT_ID_WIDTH +: ACCOUNT_ID_WIDTH] != 0) begin
                        for (j = 0; j < MAX_BATCH_TX; j = j + 1) begin  
                            // Only check if j is less than current table_size
                            if (j < table_size) begin
                                // Check read-write conflicts (current read vs existing writes)
                                if (read_dependencies[i*ACCOUNT_ID_WIDTH +: ACCOUNT_ID_WIDTH] != 0 && 
                                    read_dependencies[i*ACCOUNT_ID_WIDTH +: ACCOUNT_ID_WIDTH] == write_dependency_table[j]) begin
                                    has_conflict <= 1'b1;
                                    conflicting_id <= owner_table[j];
                                end
                                // Check write-write conflicts
                                if (write_dependencies[i*ACCOUNT_ID_WIDTH +: ACCOUNT_ID_WIDTH] != 0 && 
                                    write_dependencies[i*ACCOUNT_ID_WIDTH +: ACCOUNT_ID_WIDTH] == write_dependency_table[j]) begin
                                    has_conflict <= 1'b1;
                                    conflicting_id <= owner_table[j];
                                end
                                // Check write-read conflicts (current write vs existing reads)
                                if (write_dependencies[i*ACCOUNT_ID_WIDTH +: ACCOUNT_ID_WIDTH] != 0 && 
                                    write_dependencies[i*ACCOUNT_ID_WIDTH +: ACCOUNT_ID_WIDTH] == read_dependency_table[j]) begin
                                    has_conflict <= 1'b1;
                                    conflicting_id <= owner_table[j];
                                end
                            end
                        end
                    end
                end
                
                // Set filter_ready if no conflicts found
                filter_ready <= !has_conflict;
            end
            else if (waiting_for_acceptance) begin
                if (has_conflict) begin
                    // If conflict detected, clear waiting state immediately
                    waiting_for_acceptance <= 1'b0;
                    filter_ready <= 1'b0;
                end
                else if (accepted_id == current_transaction_id) begin
                    // Transaction was accepted, update tables
                    for (i = 0; i < MAX_TX_DEPENDENCIES; i = i + 1) begin
                        if (current_read_deps[i*64 +: 64] != 0) begin
                            if (table_size < TOTAL_TABLE_SIZE) begin
                                read_dependency_table[table_size] <= current_read_deps[i*64 +: 64];
                                owner_table[table_size] <= current_transaction_id;
                                table_size <= table_size + 1;
                            end
                        end
                        if (current_write_deps[i*64 +: 64] != 0) begin
                            if (table_size < TOTAL_TABLE_SIZE) begin
                                write_dependency_table[table_size] <= current_write_deps[i*64 +: 64];
                                owner_table[table_size] <= current_transaction_id;
                                table_size <= table_size + 1;
                            end
                        end
                    end
                    waiting_for_acceptance <= 1'b0;
                end
            end
            else begin
                // When not processing make sure the clear conflict flags
                has_conflict <= 1'b0;
                conflicting_id <= 64'd0;
            end
        end
    end
endmodule
