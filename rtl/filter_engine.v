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

    // Dependency tables
    reg [63:0] read_dependency_table [TABLE_SIZE-1:0];   // Table for MAX_TRANSACTIONS * DEPS_PER_TRANSACTION each
    reg [63:0] write_dependency_table [TABLE_SIZE-1:0];  // Table for MAX_TRANSACTIONS * DEPS_PER_TRANSACTION each
    reg [63:0] owner_table [TABLE_SIZE-1:0];            // Store owner ID for each dependency
    reg [TABLE_INDEX_BITS-1:0] table_size;    // Current size of tables
    
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
            for (i = 0; i < TABLE_SIZE; i = i + 1) begin
                read_dependency_table[i] <= 64'd0;
                write_dependency_table[i] <= 64'd0;
                owner_table[i] <= 64'd0;
            end
        end
        else begin
            // Default values
            filter_ready <= 1'b0;
            
            if (pipeline_ready) begin
                if (transaction_forwarded) begin
                    // Store the dependencies for this transaction
                    current_transaction_id <= owner_programID;
                    current_read_deps <= read_dependencies;
                    current_write_deps <= write_dependencies;
                    waiting_for_acceptance <= 1'b1;
                    
                    // Clear conflict flag before checking
                    has_conflict <= 1'b0;
                    conflicting_id <= 64'd0;
                    
                    // Check against dependency tables
                    for (i = 0; i < table_size; i = i + 1) begin
                        for (j = 0; j < DEPS_PER_TRANSACTION; j = j + 1) begin
                            // Check read-write conflicts (current read vs existing writes)
                            if (read_dependencies[j*64 +: 64] == write_dependency_table[i] && 
                                read_dependencies[j*64 +: 64] != 0) begin
                                has_conflict <= 1'b1;
                                conflicting_id <= owner_table[i];
                            end
                            // Check write-write conflicts
                            if (write_dependencies[j*64 +: 64] == write_dependency_table[i] && 
                                write_dependencies[j*64 +: 64] != 0) begin
                                has_conflict <= 1'b1;
                                conflicting_id <= owner_table[i];
                            end
                            // Check write-read conflicts (current write vs existing reads)
                            if (write_dependencies[j*64 +: 64] == read_dependency_table[i] && 
                                write_dependencies[j*64 +: 64] != 0) begin
                                has_conflict <= 1'b1;
                                conflicting_id <= owner_table[i];
                            end
                        end
                    end
                    
                    // Only set filter_ready if no conflicts found
                    filter_ready <= !has_conflict;
                end
                else begin
                    // Reset state when no transaction
                    waiting_for_acceptance <= 1'b0;
                    has_conflict <= 1'b0;
                    conflicting_id <= 64'd0;
                end
            end
            else if (waiting_for_acceptance && !has_conflict && accepted_id == current_transaction_id) begin
                // Only update tables if transaction was accepted and had no conflicts
                if (table_size < TABLE_SIZE) begin
                    for (j = 0; j < DEPS_PER_TRANSACTION; j = j + 1) begin
                        // Only store non-zero dependencies
                        if (current_read_deps[j*64 +: 64] != 64'd0) begin
                            read_dependency_table[table_size] <= current_read_deps[j*64 +: 64];
                            owner_table[table_size] <= current_transaction_id;
                            table_size <= table_size + 1'b1;
                        end
                        if (current_write_deps[j*64 +: 64] != 64'd0) begin
                            write_dependency_table[table_size] <= current_write_deps[j*64 +: 64];
                            owner_table[table_size] <= current_transaction_id;
                            table_size <= table_size + 1'b1;
                        end
                    end
                end
                waiting_for_acceptance <= 1'b0;
            end
        end
    end
endmodule
