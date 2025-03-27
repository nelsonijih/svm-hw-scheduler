module top #(
    parameter NUM_PARALLEL_INSTANCES = 4,
    parameter MAX_DEPENDENCIES = 256,
    parameter MAX_BATCH_SIZE = 8,
    parameter BATCH_TIMEOUT_CYCLES = 100,
    parameter MAX_PENDING_TRANSACTIONS = 16,
    parameter INSERTION_QUEUE_DEPTH = 8,
    parameter MAX_BATCHES = 16          // Maximum number of concurrent batches
) (
    input wire clk,
    input wire rst_n,
    
    // AXI-Stream input interface
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire [63:0] s_axis_tdata_owner_programID,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_read_dependencies,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_write_dependencies,
    
    // AXI-Stream output interface (one per instance)
    output wire [NUM_PARALLEL_INSTANCES-1:0] m_axis_tvalid,
    input wire [NUM_PARALLEL_INSTANCES-1:0] m_axis_tready,
    output wire [NUM_PARALLEL_INSTANCES-1:0][63:0] m_axis_tdata_owner_programID,
    output wire [NUM_PARALLEL_INSTANCES-1:0][MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies,
    output wire [NUM_PARALLEL_INSTANCES-1:0][MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies,
    
    // Aggregated performance monitoring
    output reg [31:0] total_raw_conflicts,
    output reg [31:0] total_waw_conflicts,
    output reg [31:0] total_war_conflicts,
    output reg [31:0] total_filter_hits,
    output reg [31:0] total_queue_occupancy,
    output reg [31:0] total_transactions_processed,
    output reg [31:0] total_transactions_batched,
    output reg [31:0] total_batch_stall_count,
    output reg [31:0] total_current_batch_size,
    output reg [31:0] total_transactions_in_queue,
    output reg [31:0] total_transactions_in_batch,
    output wire [NUM_PARALLEL_INSTANCES-1:0] batch_completed,
    output reg [31:0] global_conflicts  // New: track global conflicts
);

    // Round-robin instance selection
    reg [$clog2(NUM_PARALLEL_INSTANCES)-1:0] current_instance;
    
    // Per-instance signals
    wire [NUM_PARALLEL_INSTANCES-1:0] instance_tready;
    wire [31:0] instance_raw_conflicts [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_waw_conflicts [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_war_conflicts [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_filter_hits [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_queue_occupancy [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_transactions_processed [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_transactions_batched [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_batch_stall_count [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_current_batch_size [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_transactions_in_queue [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_transactions_in_batch [NUM_PARALLEL_INSTANCES-1:0];
    
    // Batch dependency signals
    wire [NUM_PARALLEL_INSTANCES-1:0] instance_new_batch_valid;
    wire [MAX_DEPENDENCIES-1:0] instance_batch_read_deps [NUM_PARALLEL_INSTANCES-1:0];
    wire [MAX_DEPENDENCIES-1:0] instance_batch_write_deps [NUM_PARALLEL_INSTANCES-1:0];
    wire [63:0] instance_batch_owner_id [NUM_PARALLEL_INSTANCES-1:0];  // Added: Owner ID for each batch
    
    // Global dependency tracking
    wire [MAX_DEPENDENCIES-1:0] global_read_dependencies;
    wire [MAX_DEPENDENCIES-1:0] global_write_dependencies;
    wire has_global_conflict;
    wire [2:0] global_conflict_type; // [RAW, WAW, WAR]
    wire [31:0] global_conflict_count;
    wire [31:0] raw_conflicts_count;  // Added: Specific conflict counters
    wire [31:0] waw_conflicts_count;
    wire [31:0] war_conflicts_count;
    
    // Batch completion tracking
    wire active_batch_found;  // Indicates if any instance has a new batch
    reg [3:0] new_batch_id;   // ID of the instance with a new batch
    wire [MAX_DEPENDENCIES-1:0] new_batch_read_deps;  // New batch's read dependencies
    wire [MAX_DEPENDENCIES-1:0] new_batch_write_deps; // New batch's write dependencies
    wire [63:0] new_batch_owner_id;  // Added: Owner ID for new batch
    reg [3:0] completed_batch_id;  // ID of the instance with a completed batch
    
    // Input demux signals
    reg [NUM_PARALLEL_INSTANCES-1:0] instance_tvalid;
    
    // Round-robin instance selection logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_instance <= 0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            // Move to next instance when transaction is accepted
            current_instance <= current_instance + 1;
            if (current_instance == NUM_PARALLEL_INSTANCES - 1)
                current_instance <= 0;
        end
    end
    
    // Input demux logic with global conflict filtering and transaction rejection
    always @(*) begin
        instance_tvalid = 0;
        if (s_axis_tvalid) begin
            if (!has_global_conflict) begin
                // Only route transaction if it doesn't conflict globally
                instance_tvalid[current_instance] = 1'b1;
            end else begin
                // When conflict detected, we don't forward the transaction
                // This implements the behavior from memory #208a1a5a:
                // "Conflicting transaction is dropped at conflict_checker"
                // "Must be resubmitted from upstream logic"
                instance_tvalid[current_instance] = 1'b0;
            end
        end
    end
    
    // Connect input ready signal - ALWAYS ready even if there's a conflict
    // This is critical - we want to consume (and drop) conflicting transactions
    // rather than stalling the pipeline
    assign s_axis_tready = instance_tready[current_instance] || has_global_conflict;
    
    // Debug output for conflict detection
    always @(posedge clk) begin
        if (s_axis_tvalid && has_global_conflict) begin
            $display("TOP: CONFLICT DETECTED - Transaction %0d rejected due to conflict", s_axis_tdata_owner_programID);
        end
    end
    
    // Instantiate multiple batcher modules
    genvar i;
    generate
        for (i = 0; i < NUM_PARALLEL_INSTANCES; i = i + 1) begin : batcher_inst
            batcher #(
                .MAX_DEPENDENCIES(MAX_DEPENDENCIES),
                .MAX_BATCH_SIZE(MAX_BATCH_SIZE),
                .BATCH_TIMEOUT_CYCLES(BATCH_TIMEOUT_CYCLES),
                .MAX_PENDING_TRANSACTIONS(MAX_PENDING_TRANSACTIONS),
                .INSERTION_QUEUE_DEPTH(INSERTION_QUEUE_DEPTH)
            ) batcher_inst (
                .clk(clk),
                .rst_n(rst_n),
                
                // Input interface
                .s_axis_tvalid(instance_tvalid[i]),
                .s_axis_tready(instance_tready[i]),
                .s_axis_tdata_owner_programID(s_axis_tdata_owner_programID),
                .s_axis_tdata_read_dependencies(s_axis_tdata_read_dependencies),
                .s_axis_tdata_write_dependencies(s_axis_tdata_write_dependencies),
                
                // Output interface
                .m_axis_tvalid(m_axis_tvalid[i]),
                .m_axis_tready(m_axis_tready[i]),
                .m_axis_tdata_owner_programID(m_axis_tdata_owner_programID[i]),
                .m_axis_tdata_read_dependencies(m_axis_tdata_read_dependencies[i]),
                .m_axis_tdata_write_dependencies(m_axis_tdata_write_dependencies[i]),
                
                // Performance monitoring
                .raw_conflicts(instance_raw_conflicts[i]),
                .waw_conflicts(instance_waw_conflicts[i]),
                .war_conflicts(instance_war_conflicts[i]),
                .filter_hits(instance_filter_hits[i]),
                .queue_occupancy(instance_queue_occupancy[i]),
                .transactions_processed(instance_transactions_processed[i]),
                .transactions_batched(instance_transactions_batched[i]),
                .batch_stall_count(instance_batch_stall_count[i]),
                .current_batch_size(instance_current_batch_size[i]),
                .transactions_in_queue(instance_transactions_in_queue[i]),
                .transactions_in_batch(instance_transactions_in_batch[i]),
                .batch_completed(batch_completed[i]),
                
                // Global dependency interface
                .new_batch_valid(instance_new_batch_valid[i]),
                .batch_read_deps_union(instance_batch_read_deps[i]),
                .batch_write_deps_union(instance_batch_write_deps[i]),
                .batch_owner_id(instance_batch_owner_id[i])
            );
        end
    endgenerate
    
    // Logic to select new batch and its dependencies
    assign active_batch_found = |instance_new_batch_valid;
    assign new_batch_read_deps = 
        instance_new_batch_valid[0] ? instance_batch_read_deps[0] :
        instance_new_batch_valid[1] ? instance_batch_read_deps[1] :
        instance_new_batch_valid[2] ? instance_batch_read_deps[2] :
        instance_batch_read_deps[3];
        
    assign new_batch_write_deps = 
        instance_new_batch_valid[0] ? instance_batch_write_deps[0] :
        instance_new_batch_valid[1] ? instance_batch_write_deps[1] :
        instance_new_batch_valid[2] ? instance_batch_write_deps[2] :
        instance_batch_write_deps[3];
        
    // Select the owner ID for the new batch
    assign new_batch_owner_id = 
        instance_new_batch_valid[0] ? instance_batch_owner_id[0] :
        instance_new_batch_valid[1] ? instance_batch_owner_id[1] :
        instance_new_batch_valid[2] ? instance_batch_owner_id[2] :
        instance_batch_owner_id[3];

    // Determine new batch ID and completed batch ID
    always @(*) begin
        // Find ID of instance with new batch
        new_batch_id = 0;
        for (int i = 0; i < NUM_PARALLEL_INSTANCES; i = i + 1) begin
            if (instance_new_batch_valid[i]) begin
                new_batch_id = i[3:0];
            end
        end
        
        // Find ID of instance with completed batch
        completed_batch_id = 0;
        for (int i = 0; i < NUM_PARALLEL_INSTANCES; i = i + 1) begin
            if (batch_completed[i]) begin
                completed_batch_id = i[3:0];
            end
        end
    end
    
    // Instantiate the conflict manager
    conflict_manager #(
        .MAX_DEPENDENCIES(MAX_DEPENDENCIES),
        .MAX_BATCHES(MAX_BATCHES)
    ) cm_inst (
        .clk(clk),
        .rst_n(rst_n),
        
        // Transaction interface
        .txn_valid(s_axis_tvalid),
        .txn_read_deps(s_axis_tdata_read_dependencies),
        .txn_write_deps(s_axis_tdata_write_dependencies),
        .txn_owner_id(s_axis_tdata_owner_programID),  // Connect owner ID
        .has_conflict(has_global_conflict),
        .conflict_type(global_conflict_type),
        
        // New batch registration
        .new_batch_valid(|instance_new_batch_valid),
        .new_batch_id(new_batch_id),
        .new_batch_read_deps(new_batch_read_deps),
        .new_batch_write_deps(new_batch_write_deps),
        .new_batch_owner_id(new_batch_owner_id),      // Connect batch owner ID
        
        // Batch completion
        .batch_completed(|batch_completed),
        .batch_id(completed_batch_id),
        
        // Global dependencies
        .global_read_dependencies(global_read_dependencies),
        .global_write_dependencies(global_write_dependencies),
        
        // Performance monitoring
        .global_conflicts(global_conflict_count),
        .raw_conflict_count(raw_conflicts_count),     // Connect specific counters
        .waw_conflict_count(waw_conflicts_count),
        .war_conflict_count(war_conflicts_count)
    );
    
    // Update global conflicts counter - now using direct counters from global dependency manager
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_conflicts <= 0;
            total_filter_hits <= 0;
            total_raw_conflicts <= 0;
            total_waw_conflicts <= 0;
            total_war_conflicts <= 0;
        end else begin
            // Use the counters directly from the global dependency manager
            global_conflicts <= global_conflict_count;
            
            // Update filter hits and specific conflict counters whenever a conflict is detected
            if (s_axis_tvalid && has_global_conflict) begin
                total_filter_hits <= total_filter_hits + 1;
                
                // Update specific conflict counters based on conflict type
                if (global_conflict_type[2]) // RAW conflict
                    total_raw_conflicts <= total_raw_conflicts + 1;
                if (global_conflict_type[1]) // WAW conflict
                    total_waw_conflicts <= total_waw_conflicts + 1;
                if (global_conflict_type[0]) // WAR conflict
                    total_war_conflicts <= total_war_conflicts + 1;
                    
                // Debug output for conflicts
                $display("CONFLICT DETECTED - Type: [RAW=%0d, WAW=%0d, WAR=%0d], Transaction ID: %0d",
                         global_conflict_type[2], global_conflict_type[1], global_conflict_type[0], s_axis_tdata_owner_programID);
            end
        end
    end
    
    // Aggregate performance counters
    integer j;
    always @(*) begin
        // Conflict counters are now handled directly in the sequential block above
        // to avoid double counting. We no longer aggregate instance conflict counters.
        
        // Other counters are still aggregated from instances
        total_queue_occupancy = 0;
        total_transactions_processed = 0;
        total_transactions_batched = 0;
        total_batch_stall_count = 0;
        total_current_batch_size = 0;
        total_transactions_in_queue = 0;
        total_transactions_in_batch = 0;
        
        for (j = 0; j < NUM_PARALLEL_INSTANCES; j = j + 1) begin
            // Skip conflict counters to avoid double counting
            // total_filter_hits is also handled in the sequential block above
            total_queue_occupancy = total_queue_occupancy + instance_queue_occupancy[j];
            total_transactions_processed = total_transactions_processed + instance_transactions_processed[j];
            total_transactions_batched = total_transactions_batched + instance_transactions_batched[j];
            total_batch_stall_count = total_batch_stall_count + instance_batch_stall_count[j];
            total_current_batch_size = total_current_batch_size + instance_current_batch_size[j];
            total_transactions_in_queue = total_transactions_in_queue + instance_transactions_in_queue[j];
            total_transactions_in_batch = total_transactions_in_batch + instance_transactions_in_batch[j];
        end
    end

endmodule
