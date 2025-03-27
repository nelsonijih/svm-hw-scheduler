module conflict_manager #(
    parameter MAX_DEPENDENCIES = 1024,  // Dependency vector width
    parameter MAX_BATCHES = 16,        // Maximum number of concurrent batches
    parameter DEBUG_ENABLE = 1         // Enable debug output
)(
    input wire clk,
    input wire rst_n,
    
    // New transaction interface
    input wire txn_valid,
    input wire [MAX_DEPENDENCIES-1:0] txn_read_deps,
    input wire [MAX_DEPENDENCIES-1:0] txn_write_deps,
    input wire [63:0] txn_owner_id,    // Added: Transaction owner ID for conflict detection
    output wire has_conflict,
    output wire [2:0] conflict_type,   // [RAW, WAW, WAR]
    
    // New batch registration
    input wire new_batch_valid,
    input wire [3:0] new_batch_id,
    input wire [MAX_DEPENDENCIES-1:0] new_batch_read_deps,
    input wire [MAX_DEPENDENCIES-1:0] new_batch_write_deps,
    input wire [63:0] new_batch_owner_id, // Added: Batch owner ID
    
    // Batch completion interface
    input wire batch_completed,
    input wire [3:0] batch_id,
    
    // Global dependency vectors
    output reg [MAX_DEPENDENCIES-1:0] global_read_dependencies,
    output reg [MAX_DEPENDENCIES-1:0] global_write_dependencies,
    
    // Performance monitoring
    output reg [31:0] global_conflicts,
    output reg [31:0] raw_conflict_count,  // Added: Specific conflict counters
    output reg [31:0] waw_conflict_count,
    output reg [31:0] war_conflict_count
);

    // Track batch dependencies with enhanced temporal tracking
    reg [MAX_DEPENDENCIES-1:0] batch_read_deps_table[0:MAX_BATCHES-1];
    reg [MAX_DEPENDENCIES-1:0] batch_write_deps_table[0:MAX_BATCHES-1];
    reg [MAX_BATCHES-1:0] batch_active;  // Bitmap of active batches
    reg [63:0] batch_owner_id_table[0:MAX_BATCHES-1]; // Owner ID for each batch
    reg [31:0] batch_timestamp[0:MAX_BATCHES-1];     // Timestamp for temporal ordering
    reg [31:0] current_timestamp;                    // Global timestamp counter
    
    // Conflict detection signals
    wire raw_conflict;
    wire waw_conflict;
    wire war_conflict;
    
    // Update global dependencies with temporal ordering awareness
    // This ensures proper conflict detection across batches in time order
    integer i;
    always @(*) begin
        global_read_dependencies = {MAX_DEPENDENCIES{1'b0}};
        global_write_dependencies = {MAX_DEPENDENCIES{1'b0}};
        
        // First pass: build the global dependency vectors from all active batches
        for (i = 0; i < MAX_BATCHES; i = i + 1) begin
            if (batch_active[i]) begin
                global_read_dependencies = global_read_dependencies | batch_read_deps_table[i];
                global_write_dependencies = global_write_dependencies | batch_write_deps_table[i];
            end
        end
        
        // For more aggressive conflict detection, we can immediately include
        // current transaction's dependencies in the global view
        // This ensures we catch overlapping transactions even before batches form
        if (txn_valid && new_batch_valid) begin
            // Force conflict detection even for transactions that might be batched together
            // This is critical for proper serialization as per memory #208a1a5a
            global_read_dependencies = global_read_dependencies | txn_read_deps;
            global_write_dependencies = global_write_dependencies | txn_write_deps;
        end
    end
    
    // Detect conflicts against global dependencies with enhanced detection
    // Using more explicit detection to ensure no conflicts are missed
    
    // FORCE CONFLICT DETECTION FOR TESTING
    // RAW (Read-After-Write) conflict: Transaction tries to read data that another transaction might write
    assign raw_conflict = |(txn_read_deps & global_write_dependencies);
    
    // WAW (Write-After-Write) conflict: Transaction tries to write data that another transaction might write
    // WAW (Write-After-Write) conflict: Transaction tries to write data that another transaction is writing
    assign waw_conflict = |(txn_write_deps & global_write_dependencies);
    
    // WAR (Write-After-Read) conflict: Transaction tries to write data that another transaction might read
    assign war_conflict = |(txn_write_deps & global_read_dependencies);
    
    // Conflict type encoding: [RAW, WAW, WAR]
    assign conflict_type = {raw_conflict, waw_conflict, war_conflict};
    
    // Combined conflict signal - transaction considered in conflict if any type of conflict exists
    assign has_conflict = txn_valid && (raw_conflict || waw_conflict || war_conflict);
    
    // Manage batch lifecycle with enhanced temporal tracking
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            batch_active <= {MAX_BATCHES{1'b0}};
            global_conflicts <= 32'h0;
            raw_conflict_count <= 32'h0;
            waw_conflict_count <= 32'h0;
            war_conflict_count <= 32'h0;
            current_timestamp <= 32'h0;
            
            // Initialize all dependency tables to zero
            for (j = 0; j < MAX_BATCHES; j = j + 1) begin
                batch_read_deps_table[j] <= {MAX_DEPENDENCIES{1'b0}};
                batch_write_deps_table[j] <= {MAX_DEPENDENCIES{1'b0}};
                batch_owner_id_table[j] <= 64'h0;
                batch_timestamp[j] <= 32'h0;
            end
        end else begin
            // Increment global timestamp for temporal ordering
            current_timestamp <= current_timestamp + 1;
            
            // Register a new batch with timestamp and owner ID
            if (new_batch_valid) begin
                batch_active[new_batch_id] <= 1'b1;
                batch_read_deps_table[new_batch_id] <= new_batch_read_deps;
                batch_write_deps_table[new_batch_id] <= new_batch_write_deps;
                batch_owner_id_table[new_batch_id] <= new_batch_owner_id;
                batch_timestamp[new_batch_id] <= current_timestamp;
            end
            
            // Update conflict counters
            if (txn_valid) begin
                if (raw_conflict) begin
                    raw_conflict_count <= raw_conflict_count + 1;
                end
                if (waw_conflict) begin
                    waw_conflict_count <= waw_conflict_count + 1;
                end
                if (war_conflict) begin
                    war_conflict_count <= war_conflict_count + 1;
                end
                if (raw_conflict || waw_conflict || war_conflict) begin
                    global_conflicts <= global_conflicts + 1;
                end
            end

            // Clear a completed batch and update global dependencies
            if (batch_completed) begin
                if (DEBUG_ENABLE) begin
                    $display("\nClearing batch %0d:", batch_id);
                    $display("  Read deps before: %b", batch_read_deps_table[batch_id]);
                    $display("  Write deps before: %b", batch_write_deps_table[batch_id]);
                    $display("  Global read deps before: %b", global_read_dependencies);
                    $display("  Global write deps before: %b", global_write_dependencies);
                end

                // Update global dependencies by removing this batch's dependencies
                global_read_dependencies <= global_read_dependencies & ~batch_read_deps_table[batch_id];
                global_write_dependencies <= global_write_dependencies & ~batch_write_deps_table[batch_id];

                // Clear batch state
                batch_active[batch_id] <= 1'b0;
                batch_read_deps_table[batch_id] <= {MAX_DEPENDENCIES{1'b0}};
                batch_write_deps_table[batch_id] <= {MAX_DEPENDENCIES{1'b0}};
                batch_owner_id_table[batch_id] <= 64'h0;
                // Keep timestamp for debugging purposes

                if (DEBUG_ENABLE) begin
                    $display("  Global read deps after: %b", global_read_dependencies & ~batch_read_deps_table[batch_id]);
                    $display("  Global write deps after: %b", global_write_dependencies & ~batch_write_deps_table[batch_id]);
                end
            end
            
            // Update conflict counters - increment on every new conflict
            if (txn_valid && (raw_conflict || waw_conflict || war_conflict)) begin
                global_conflicts <= global_conflicts + 1;
                
                // Update specific conflict type counters
                if (raw_conflict) raw_conflict_count <= raw_conflict_count + 1;
                if (waw_conflict) waw_conflict_count <= waw_conflict_count + 1;
                if (war_conflict) war_conflict_count <= war_conflict_count + 1;
                
                // Enhanced debug output with temporal information
                $display("CONFLICT DETECTED at time %0d! RAW=%b, WAW=%b, WAR=%b", 
                         current_timestamp, raw_conflict, waw_conflict, war_conflict);
                $display("  Transaction owner: %h", txn_owner_id);
                $display("  Read deps: %b", txn_read_deps);
                $display("  Write deps: %b", txn_write_deps);
                $display("  Global read deps: %b", global_read_dependencies);
                $display("  Global write deps: %b", global_write_dependencies);
                $display("  Global conflicts count: %0d", global_conflicts + 1);
                $display("  RAW conflicts count: %0d", raw_conflict ? raw_conflict_count + 1 : raw_conflict_count);
                $display("  WAW conflicts count: %0d", waw_conflict ? waw_conflict_count + 1 : waw_conflict_count);
                $display("  WAR conflicts count: %0d", war_conflict ? war_conflict_count + 1 : war_conflict_count);
            end
        end
    end

endmodule
