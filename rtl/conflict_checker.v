module conflict_checker #(
    parameter MAX_DEPENDENCIES = 256,    // Dependency vector width
    parameter CHUNK_SIZE      = 64,      // Size of each parallel check chunk
    parameter NUM_PARALLEL_CHECKS = 4,    // Number of parallel checkers
    parameter DEBUG_ENABLE     = 1       // Enable debug output
)(
    input wire clk,
    input wire rst_n,
    
    // AXI-Stream Input
    input wire s_axis_tvalid,
    output reg s_axis_tready,
    input wire [63:0] s_axis_tdata_owner_programID,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_read_dependencies,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_write_dependencies,
    
    // AXI-Stream Output
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg [63:0] m_axis_tdata_owner_programID,
    output reg [MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies,
    output reg [MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies,
    // Note: has_conflict signal removed as only non-conflicting transactions are forwarded
    
    // Batch control
    input wire batch_completed,
    
    // Performance monitoring
    output reg [31:0] raw_conflicts,
    output reg [31:0] waw_conflicts,
    output reg [31:0] war_conflicts,
    output reg [31:0] filter_hits,
    output reg [31:0] transactions_processed,
    output reg [31:0] transactions_in_queue,
    output reg [31:0] transactions_in_batch
);

// Batch dependency tracking
reg [MAX_DEPENDENCIES-1:0] batch_read_dependencies;
reg [MAX_DEPENDENCIES-1:0] batch_write_dependencies;

// Previous transaction dependencies (for conflict detection)
reg [MAX_DEPENDENCIES-1:0] prev_read_deps;
reg [MAX_DEPENDENCIES-1:0] prev_write_deps;

// Track if we need to check against previous transaction
reg prev_transaction_valid;

// Handshaking register
reg m_axis_tready_pipe;

// Pipeline registers
reg [63:0] owner_pipe;
reg [MAX_DEPENDENCIES-1:0] read_deps_pipe;
reg [MAX_DEPENDENCIES-1:0] write_deps_pipe;
reg transaction_valid_pipe;  // Track if transaction is valid in pipeline

// Conflict detection signals for batch dependencies
wire [NUM_PARALLEL_CHECKS-1:0] raw_conflict;
wire [NUM_PARALLEL_CHECKS-1:0] waw_conflict;
wire [NUM_PARALLEL_CHECKS-1:0] war_conflict;

// Aggregated conflict signals
wire has_raw_batch_conflict;
wire has_waw_batch_conflict;
wire has_war_batch_conflict;
wire has_any_batch_conflict;

// Direct conflict detection signals
reg has_raw_conflict;
reg has_waw_conflict;
reg has_war_conflict;

// Transaction conflict status
reg transaction_has_conflict;  // Set to 1 if current transaction has any conflict

// Debug flag for verbose output
reg debug_verbose = DEBUG_ENABLE ? 1'b1 : 1'b0;

// Debug initialization message
initial begin
    if (DEBUG_ENABLE)
        $display("Conflict checker module initialized with %d parallel checkers", NUM_PARALLEL_CHECKS);
end

// Parallel check generators
genvar i;
generate
    for (i = 0; i < NUM_PARALLEL_CHECKS; i = i + 1) begin : conflict_check
        localparam [31:0] START_BIT = i * CHUNK_SIZE;
        localparam [31:0] END_BIT = ((i+1) * CHUNK_SIZE - 1) < (MAX_DEPENDENCIES-1) ? ((i+1) * CHUNK_SIZE - 1) : (MAX_DEPENDENCIES-1);
        
        // RAW: Read vs existing writes
        assign raw_conflict[i] = |(read_deps_pipe[END_BIT:START_BIT] & 
                                 batch_write_dependencies[END_BIT:START_BIT]);
                                 
        // WAW: Write vs existing writes  
        assign waw_conflict[i] = |(write_deps_pipe[END_BIT:START_BIT] & 
                                 batch_write_dependencies[END_BIT:START_BIT]);
                                 
        // WAR: Write vs existing reads
        assign war_conflict[i] = |(write_deps_pipe[END_BIT:START_BIT] & 
                                 batch_read_dependencies[END_BIT:START_BIT]);
                                 
        // Debug: Print chunk-specific conflicts when they occur
        always @(posedge clk) begin
            if (DEBUG_ENABLE && transaction_valid_pipe && (raw_conflict[i] || waw_conflict[i] || war_conflict[i])) begin
                $display("Time %0t: Chunk %0d (bits %0d:%0d) has conflicts: RAW=%b, WAW=%b, WAR=%b", 
                         $time, i, START_BIT, END_BIT, raw_conflict[i], waw_conflict[i], war_conflict[i]);
            end
        end
    end
endgenerate

// FSM states - Enhanced state machine for better AXI handshaking
localparam IDLE = 2'b00;    // Waiting for new transaction
localparam CHECK = 2'b01;   // Checking for conflicts
localparam OUTPUT = 2'b10;  // Waiting for output handshake
localparam COMPLETE = 2'b11; // Transaction completion
reg [1:0] state;
reg [1:0] state_prev;  // Previous state for edge detection
reg [1:0] next_state;  // For better state transition handling

// Transaction tracking
reg transaction_in_progress; // Flag to track if we're currently processing a transaction
reg transaction_completed;  // Flag to track transaction completion

// Reset counters and state
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Reset all counters
        raw_conflicts <= 32'd0;
        waw_conflicts <= 32'd0;
        war_conflicts <= 32'd0;
        filter_hits <= 32'd0;
        transactions_processed <= 32'd0;
        batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
    end else begin
        // Update transaction counter based on state transitions
        if (state == COMPLETE && state_prev != COMPLETE) begin
            transactions_processed <= transactions_processed + 32'd1;
            if (DEBUG_ENABLE)
                $display("Time %0t: Incrementing transactions_processed to %0d", $time, transactions_processed + 32'd1);
        end
        
        // Reset only dependencies when batch completes
        if (batch_completed) begin
            batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            if (DEBUG_ENABLE)
                $display("Time %0t: Batch completed - Resetting dependencies", $time);
        end
    end
end

// Batch conflict detection
assign has_raw_batch_conflict = |raw_conflict;
assign has_waw_batch_conflict = |waw_conflict;
assign has_war_batch_conflict = |war_conflict;
assign has_any_batch_conflict = has_raw_batch_conflict || has_waw_batch_conflict || has_war_batch_conflict;

// Debug initialization
initial begin
    if (DEBUG_ENABLE)
        $display("DEBUG_ENABLE parameter value: %d", DEBUG_ENABLE);
end

// Update state machine transitions
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        state_prev <= IDLE;
        transaction_completed <= 0;
        transaction_in_progress <= 0;
    end
    else begin
        // Update previous state register
        state_prev <= state;
        
        case (state)
            IDLE: begin
                if (s_axis_tvalid && s_axis_tready) begin
                    state <= CHECK;
                    transaction_in_progress <= 1;
                end
            end
            
            CHECK: begin
                // Check for conflicts with batch dependencies
                if (transaction_valid_pipe) begin
                    // Always increment transactions_processed when we check a transaction
                    transactions_processed <= transactions_processed + 1;
                    if (DEBUG_ENABLE)
                        $display("Time %0t: Incrementing transactions_processed to %0d", $time, transactions_processed + 1);
                    
                    if (has_raw_batch_conflict) begin
                        raw_conflicts <= raw_conflicts + 1;
                        has_raw_conflict <= 1'b1;
                        if (DEBUG_ENABLE)
                            $display("Time %0t: RAW conflict detected for transaction %h", $time, owner_pipe);
                    end
                    if (has_waw_batch_conflict) begin
                        waw_conflicts <= waw_conflicts + 1;
                        has_waw_conflict <= 1'b1;
                        if (DEBUG_ENABLE)
                            $display("Time %0t: WAW conflict detected for transaction %h", $time, owner_pipe);
                    end
                    if (has_war_batch_conflict) begin
                        war_conflicts <= war_conflicts + 1;
                        has_war_conflict <= 1'b1;
                        if (DEBUG_ENABLE)
                            $display("Time %0t: WAR conflict detected for transaction %h", $time, owner_pipe);
                    end
                    
                    // Update filter hits if any conflict found
                    if (has_any_batch_conflict) begin
                        filter_hits <= filter_hits + 1;
                        if (DEBUG_ENABLE)
                            $display("Time %0t: Transaction filtered due to conflicts", $time);
                    end
                end

                // Set transaction conflict status
                transaction_has_conflict = has_raw_conflict || has_waw_conflict || has_war_conflict;
                
                // Proceed to OUTPUT or COMPLETE based on conflict status
                if (!transaction_has_conflict) begin
                    state <= OUTPUT;
                    if (DEBUG_ENABLE)
                        $display("Time %0t: Transaction ID %h accepted - no conflicts", $time, owner_pipe);
                end else begin
                    state <= COMPLETE;
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: Transaction ID %h REJECTED due to conflicts (RAW=%b WAW=%b WAR=%b)", 
                                 $time, owner_pipe, has_raw_conflict, has_waw_conflict, has_war_conflict);
                        $display("  Current conflict counts - RAW: %0d, WAW: %0d, WAR: %0d, Total: %0d",
                                 raw_conflicts + (has_raw_conflict ? 32'd1 : 32'd0),
                                 waw_conflicts + (has_waw_conflict ? 32'd1 : 32'd0),
                                 war_conflicts + (has_war_conflict ? 32'd1 : 32'd0),
                                 filter_hits + 32'd1);
                    end
                end
            end
            
            OUTPUT: begin
                // Transition to COMPLETE when valid handshake occurs
                if (m_axis_tvalid && m_axis_tready_pipe) begin
                    // Transaction completed
                    state <= COMPLETE;
                    transaction_completed <= 1;
                    transaction_in_progress <= 0;
                    
                    if (DEBUG_ENABLE)
                        $display("Time %0t: Transaction completed with handshake, moving to COMPLETE state", $time);
                    
                    // Store dependencies for next conflict check
                    prev_read_deps <= read_deps_pipe;
                    prev_write_deps <= write_deps_pipe;
                    prev_transaction_valid <= 1'b1;
                    
                    // Update batch dependencies if no conflicts
                    if (!transaction_has_conflict) begin
                        batch_read_dependencies <= batch_read_dependencies | read_deps_pipe;
                        batch_write_dependencies <= batch_write_dependencies | write_deps_pipe;
                    end
                    
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: Transaction completed with handshake, moving to COMPLETE state", $time);
                    end
                end
            end
            
            COMPLETE: begin
                // Ready for next transaction - immediately transition to IDLE
                state <= IDLE;
                transaction_completed <= 0;
                s_axis_tready <= 1'b1; // Set ready for new transactions
                
                // Handle batch completion
                if (batch_completed) begin
                    // Reset transaction counter and dependencies
                    transactions_processed <= 32'd0;
                    batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
                    batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
                    prev_transaction_valid <= 1'b0;
                    prev_read_deps <= {MAX_DEPENDENCIES{1'b0}};
                    prev_write_deps <= {MAX_DEPENDENCIES{1'b0}};
                    
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: Batch completed - Resetting transaction counter and dependencies", $time);
                    end
                end
                
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: Transaction complete, moving to IDLE state", $time);
                    $display("Time %0t: Setting s_axis_tready=1 for new transactions", $time);
                end
            end
        endcase
    end
end

// Handle batch completion
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Reset all state variables
        s_axis_tready <= 1'b1;  // Ready to accept transactions after reset
        batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        m_axis_tvalid <= 1'b0;  // No valid output after reset
        m_axis_tdata_owner_programID <= 64'd0;
        m_axis_tdata_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        m_axis_tdata_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        // m_axis_tdata_has_conflict signal removed
        
        // Reset performance counters (similar to fd_pack_schedule_impl statistics)
        raw_conflicts <= 32'd0;
        waw_conflicts <= 32'd0;
        war_conflicts <= 32'd0;
        filter_hits <= 32'd0;
        transactions_processed <= 32'd0;  // Track total transactions for throughput analysis
        
        // Reset batch dependency tracking
        batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        transaction_has_conflict <= 1'b0;
        has_raw_conflict <= 1'b0;
        has_waw_conflict <= 1'b0;
        has_war_conflict <= 1'b0;
        
        // Reset AXI protocol state tracking
        transaction_in_progress <= 1'b0;
        transaction_completed <= 1'b0;
        transaction_valid_pipe <= 1'b0;  // Reset transaction valid flag
    end else begin
        if (batch_completed) begin
            if (DEBUG_ENABLE) begin
                $display("Time %0t: Batch completed - Resetting dependency tracking", $time);
                $display("  Previous batch read deps: %h", batch_read_dependencies);
                $display("  Previous batch write deps: %h", batch_write_dependencies);
                $display("  Batch statistics: RAW=%0d, WAW=%0d, WAR=%0d, Total=%0d",
                         raw_conflicts, waw_conflicts, war_conflicts, filter_hits);
            end
            // Use blocking assignment to ensure immediate update
            batch_read_dependencies = {MAX_DEPENDENCIES{1'b0}};
            batch_write_dependencies = {MAX_DEPENDENCIES{1'b0}};
            
            // Force state machine back to IDLE on batch completion
            state <= IDLE;
            s_axis_tready <= 1'b1;
            m_axis_tvalid <= 1'b0;
            transaction_valid_pipe <= 1'b0;
            transaction_in_progress <= 1'b0;
            
            // Simple verification that reset occurred
            if (DEBUG_ENABLE) begin
                $display("Time %0t: Dependencies reset verification", $time);
                $display("  batch_read_dependencies should be reset to 0");
                $display("  batch_write_dependencies should be reset to 0");
            end
            
            if (DEBUG_ENABLE) begin
                $display("Time %0t: Dependencies reset complete", $time);
                $display("  New batch read deps will be 0");
                $display("  New batch write deps will be 0");
            end
            // Don't reset counters on batch completion
            // They should accumulate across batches for performance monitoring
        end
    end
end

// Check for new transaction with proper AXI-Stream handshaking
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s_axis_tready <= 1'b1;
        transaction_valid_pipe <= 1'b0;
    end else begin
        case (state)
            IDLE: begin
                // Always be ready to accept new transactions in IDLE state
                s_axis_tready <= 1'b1;
                
                if (s_axis_tvalid && s_axis_tready) begin
                    // Latch input data
                    owner_pipe <= s_axis_tdata_owner_programID;
                    read_deps_pipe <= s_axis_tdata_read_dependencies;
                    write_deps_pipe <= s_axis_tdata_write_dependencies;
                    
                    // Set transaction flags
                    transaction_valid_pipe <= 1'b1;
                    transaction_in_progress <= 1'b1;
                    s_axis_tready <= 1'b0; // Stop accepting new transactions
                
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: IDLE state - Received new transaction with Owner ID: %h", $time, s_axis_tdata_owner_programID);
                        $display("  Read dependencies: %h", s_axis_tdata_read_dependencies);
                        $display("  Write dependencies: %h", s_axis_tdata_write_dependencies);
                        
                        // Print specific bits that are set
                        for (integer i = 0; i < MAX_DEPENDENCIES; i = i + 1) begin
                            if (s_axis_tdata_read_dependencies[i])
                                $display("    Read dependency bit %0d is set", i);
                            if (s_axis_tdata_write_dependencies[i])
                                $display("    Write dependency bit %0d is set", i);
                        end
                    end
                end
            end
            
            CHECK: begin
                // Not ready for new transactions during processing
                s_axis_tready <= 1'b0;
            end
            
            OUTPUT: begin
                // Not ready for new transactions during output
                s_axis_tready <= 1'b0;
            end
            
            COMPLETE: begin
                // Ready for new transactions
                s_axis_tready <= 1'b1;
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: COMPLETE state - Setting s_axis_tready=1", $time);
                end
            end
        endcase
    end
end

// Conflict detection
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        has_raw_conflict <= 1'b0;
        has_waw_conflict <= 1'b0;
        has_war_conflict <= 1'b0;
        transaction_has_conflict <= 1'b0;
    end else begin
        if (state == CHECK) begin
            // Check if this is the first transaction (empty batch)
            if ((batch_read_dependencies == {MAX_DEPENDENCIES{1'b0}}) && (batch_write_dependencies == {MAX_DEPENDENCIES{1'b0}})) begin
                // First transaction can't have conflicts
                has_raw_conflict <= 1'b0;
                has_waw_conflict <= 1'b0;
                has_war_conflict <= 1'b0;
                transaction_has_conflict <= 1'b0;
                
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: First transaction in batch - no conflicts possible", $time);
                    $display("  Current transaction:");
                    $display("    Read deps: %h", read_deps_pipe);
                    $display("    Write deps: %h", write_deps_pipe);
                end
            end else begin
                // Check all conflict types in parallel
                // RAW: New transaction reads from a location that was written to by a previous transaction
                has_raw_conflict <= |(read_deps_pipe & batch_write_dependencies);
                
                // WAW: New transaction writes to a location that was written to by a previous transaction
                has_waw_conflict <= |(write_deps_pipe & batch_write_dependencies);
                
                // WAR: New transaction writes to a location that was read from by a previous transaction
                has_war_conflict <= |(write_deps_pipe & batch_read_dependencies);
                
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: Checking conflicts for transaction ID: %h", $time, owner_pipe);
                    $display("  Current transaction:");
                    $display("    Read deps: %h", read_deps_pipe);
                    $display("    Write deps: %h", write_deps_pipe);
                    $display("  Current batch:");
                    $display("    Read deps: %h", batch_read_dependencies);
                    $display("    Write deps: %h", batch_write_dependencies);
                end
                
                // Update overall conflict status
                transaction_has_conflict <= |(read_deps_pipe & batch_write_dependencies) ||
                                           |(write_deps_pipe & batch_write_dependencies) ||
                                           |(write_deps_pipe & batch_read_dependencies);
                
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: Checking conflicts for transaction ID: %h", $time, owner_pipe);
                    $display("  Current transaction:");
                    $display("    Read deps: %h", read_deps_pipe);
                    $display("    Write deps: %h", write_deps_pipe);
                    $display("  Current batch:");
                    $display("    Read deps: %h", batch_read_dependencies);
                    $display("    Write deps: %h", batch_write_dependencies);
                    
                    if (transaction_has_conflict) begin
                        if (has_raw_conflict)
                            $display("  RAW conflict detected!");
                        if (has_waw_conflict)
                            $display("  WAW conflict detected!");
                        if (has_war_conflict)
                            $display("  WAR conflict detected!");
                    end
                end
            end
        end
    end
end

// Update output signals and performance counters
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // m_axis_tdata_has_conflict signal removed
        m_axis_tdata_owner_programID <= 64'd0;
        m_axis_tdata_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        m_axis_tdata_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        m_axis_tvalid <= 1'b0;
        m_axis_tready_pipe <= 1'b0;
    end else begin
        // Register m_axis_tready to synchronize with clock
        m_axis_tready_pipe <= m_axis_tready;
        
        if (state == OUTPUT) begin
            // Set output data (only non-conflicting transactions reach this point)
            m_axis_tdata_owner_programID <= owner_pipe;
            m_axis_tdata_read_dependencies <= read_deps_pipe;
            m_axis_tdata_write_dependencies <= write_deps_pipe;
            
            // Assert valid when in OUTPUT state
            m_axis_tvalid <= 1'b1;
            
            // No need to update conflict counters here anymore
            // Conflict transactions never reach this state
        end else if (state == COMPLETE) begin
            // Clear valid when in COMPLETE state
            m_axis_tvalid <= 1'b0;
            
            if (DEBUG_ENABLE) begin
                $display("Time %0t: Clearing m_axis_tvalid in COMPLETE state", $time);
            end
        end else if (state == IDLE) begin
            // Ensure valid is low in IDLE state
            m_axis_tvalid <= 1'b0;
        end
    end
end

// Update AXI protocol state tracking
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        transaction_in_progress <= 1'b0;
        transaction_completed <= 1'b0;
    end else begin
        case (state)
            IDLE: begin
                transaction_in_progress <= 1'b0;
                transaction_completed <= 1'b0;
            end
            
            CHECK: begin
                transaction_in_progress <= 1'b1;
            end
            
            OUTPUT: begin
                // Keep transaction in progress until handshake completes
                transaction_in_progress <= 1'b1;
                
                // Set completed when handshake occurs
                if (m_axis_tvalid && m_axis_tready_pipe) begin
                    transaction_completed <= 1'b1;
                end
            end
            
            COMPLETE: begin
                transaction_in_progress <= 1'b0;
                transaction_completed <= 1'b0;
                
                // Update batch dependencies for transactions without conflicts
                if (!transaction_has_conflict) begin
                    batch_read_dependencies <= batch_read_dependencies | read_deps_pipe;
                    batch_write_dependencies <= batch_write_dependencies | write_deps_pipe;
                    
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: Updating batch dependencies for non-conflicting transaction", $time);
                        $display("  Updated batch read deps: %h", batch_read_dependencies | read_deps_pipe);
                        $display("  Updated batch write deps: %h", batch_write_dependencies | write_deps_pipe);
                    end
                end
            end
        endcase
    end
end

// Update transaction counter - count all transactions that complete processing
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        transactions_processed <= 32'd0;
    end else begin
        if (batch_completed) begin
            // Reset counter when batch completes
            transactions_processed <= 32'd0;
        end else if (state == COMPLETE && state_prev != COMPLETE) begin
            // Count all transactions that complete processing, both conflicting and non-conflicting
            transactions_processed <= transactions_processed + 32'd1;
            
            if (DEBUG_ENABLE) begin
                $display("Time %0t: Incrementing transactions_processed counter to %0d", $time, transactions_processed + 32'd1);
            end
        end
    end
end

endmodule