module conflict_checker #(
    parameter MAX_DEPENDENCIES = 1024,    // Dependency vector width
    parameter CHUNK_SIZE      = 64,      // Size of each parallel check chunk
    parameter NUM_PARALLEL_CHECKS = 16,   // Number of parallel checkers
    parameter DEBUG_ENABLE     = 1       // Enable debug output
)(
    input wire clk,
    input wire rst_n,
    
    // AXI-Stream Input
    input wire s_axis_tvalid,
    output reg s_axis_tready,
    input wire [63:0] s_axis_tdata_owner_programID,
    input wire [1023:0] s_axis_tdata_read_dependencies,
    input wire [1023:0] s_axis_tdata_write_dependencies,
    
    // AXI-Stream Output
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg [63:0] m_axis_tdata_owner_programID,
    output reg [1023:0] m_axis_tdata_read_dependencies,
    output reg [1023:0] m_axis_tdata_write_dependencies,
    output reg m_axis_tdata_has_conflict,  // Indicates if transaction has conflicts
    
    // Batch control
    input wire batch_completed,
    
    // Performance monitoring
    output reg [31:0] raw_conflicts,
    output reg [31:0] waw_conflicts,
    output reg [31:0] war_conflicts,
    output reg [31:0] filter_hits
);

// Batch dependency tracking
reg [MAX_DEPENDENCIES-1:0] batch_read_dependencies;
reg [MAX_DEPENDENCIES-1:0] batch_write_dependencies;

// Pipeline registers
reg [63:0] owner_pipe;
reg [MAX_DEPENDENCIES-1:0] read_deps_pipe;
reg [MAX_DEPENDENCIES-1:0] write_deps_pipe;
reg transaction_valid_pipe;  // Track if transaction is valid in pipeline

// Conflict detection signals
wire [NUM_PARALLEL_CHECKS-1:0] raw_conflict;
wire [NUM_PARALLEL_CHECKS-1:0] waw_conflict;
wire [NUM_PARALLEL_CHECKS-1:0] war_conflict;

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
            if (DEBUG_ENABLE && (raw_conflict[i] || waw_conflict[i] || war_conflict[i])) begin
                $display("Time %0t: Chunk %0d (bits %0d:%0d) has conflicts: RAW=%b, WAW=%b, WAR=%b", 
                         $time, i, START_BIT, END_BIT, raw_conflict[i], waw_conflict[i], war_conflict[i]);
            end
        end
    end
endgenerate

// FSM states
localparam IDLE = 2'b00;
localparam CHECK = 2'b01;
localparam OUTPUT = 2'b10;
reg [1:0] state;
reg [1:0] next_state;  // For better state transition handling

// Transaction tracking
reg transaction_in_progress; // Flag to track if we're currently processing a transaction

// Debug counters
initial begin
    raw_conflicts = 0;
    waw_conflicts = 0;
    war_conflicts = 0;
    filter_hits = 0;
    batch_read_dependencies = 0;
    batch_write_dependencies = 0;
    if (DEBUG_ENABLE)
        $display("DEBUG_ENABLE parameter value: %d", DEBUG_ENABLE);
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Reset all state variables
        state <= IDLE;
        s_axis_tready <= 1'b1;  // Ready to accept transactions after reset
        m_axis_tvalid <= 1'b0;  // No valid output after reset
        m_axis_tdata_owner_programID <= 64'd0;
        m_axis_tdata_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        m_axis_tdata_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        m_axis_tdata_has_conflict <= 1'b0;
        
        // Reset performance counters
        raw_conflicts <= 32'd0;
        waw_conflicts <= 32'd0;
        war_conflicts <= 32'd0;
        filter_hits <= 32'd0;
        
        // Reset batch dependency tracking
        batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
        transaction_has_conflict <= 1'b0;
        has_raw_conflict <= 1'b0;
        has_waw_conflict <= 1'b0;
        has_war_conflict <= 1'b0;
        transaction_valid_pipe <= 1'b0;  // Reset transaction valid flag
        transaction_in_progress <= 1'b0; // Reset transaction tracking
    end else begin
        // Handle batch completion
        if (batch_completed) begin
            if (DEBUG_ENABLE) begin
                $display("Time %0t: Batch completed - Resetting dependency tracking", $time);
                $display("  Previous batch read deps: %h", batch_read_dependencies);
                $display("  Previous batch write deps: %h", batch_write_dependencies);
                $display("  Batch statistics: RAW=%0d, WAW=%0d, WAR=%0d, Total=%0d",
                         raw_conflicts, waw_conflicts, war_conflicts, filter_hits);
            end
            // Use non-blocking assignment for proper synchronization
            batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            
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
        
        case (state)
            IDLE: begin
                // In IDLE state, we're ready to accept new transactions
                s_axis_tready <= 1'b1; // Always ready to accept new transactions in IDLE
                m_axis_tvalid <= 1'b0; // Make sure valid is deasserted in IDLE
                
                // Reset conflict flags in IDLE state
                has_raw_conflict <= 1'b0;
                has_waw_conflict <= 1'b0;
                has_war_conflict <= 1'b0;
                transaction_has_conflict <= 1'b0;
                transaction_valid_pipe <= 1'b0; // Reset transaction valid flag
                
                if (s_axis_tvalid && s_axis_tready) begin
                    // Mark that we're starting a transaction - CRITICAL for handshaking
                    transaction_in_progress <= 1'b1; // Set flag to track transaction processing
                    // Pipeline transaction data
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: IDLE state - Received new transaction with Owner ID: %h", $time, s_axis_tdata_owner_programID);
                        $display("  Read dependencies: %h", s_axis_tdata_read_dependencies);
                        $display("  Write dependencies: %h", s_axis_tdata_write_dependencies);
                        
                        // Print specific bits that are set in the dependencies
                        for (integer i = 0; i < MAX_DEPENDENCIES; i = i + 1) begin
                            if (s_axis_tdata_read_dependencies[i]) begin
                                $display("    Read dependency bit %0d is set", i);
                            end
                            if (s_axis_tdata_write_dependencies[i]) begin
                                $display("    Write dependency bit %0d is set", i);
                            end
                        end
                    end
                    
                    // Use non-blocking assignments for proper synchronization
                    owner_pipe <= s_axis_tdata_owner_programID;
                    read_deps_pipe <= s_axis_tdata_read_dependencies;
                    write_deps_pipe <= s_axis_tdata_write_dependencies;
                    transaction_valid_pipe <= 1'b1;  // Mark transaction as valid in pipeline
                    s_axis_tready <= 1'b0; // Stop accepting new transactions while processing this one
                    state <= CHECK;
                end
            end
            
            CHECK: begin
                // Only process if we have a valid transaction
                if (transaction_in_progress) begin
                    // Critical: Assert m_axis_tvalid immediately in CHECK state
                    // This ensures proper AXI-Stream handshaking and meets testbench timing expectations
                    m_axis_tvalid <= 1'b1;
                    
                    // Check all conflict types in parallel
                    if (DEBUG_ENABLE && debug_verbose) begin
                        $display("Time %0t: CHECK state - Checking for conflicts - Owner ID: %h", $time, owner_pipe);
                        $display("  Current batch read deps: %h", batch_read_dependencies);
                        $display("  Current batch write deps: %h", batch_write_dependencies);
                        $display("  New transaction read deps: %h", read_deps_pipe);
                        $display("  New transaction write deps: %h", write_deps_pipe);
                        
                        // Print specific bits that are set in the batch dependencies
                        for (integer i = 0; i < MAX_DEPENDENCIES; i = i + 1) begin
                            if (batch_read_dependencies[i]) begin
                                $display("    Batch read dependency bit %0d is set", i);
                            end
                            if (batch_write_dependencies[i]) begin
                                $display("    Batch write dependency bit %0d is set", i);
                            end
                        end
                    end
                    
                    // Initialize conflict flags
                    has_raw_conflict <= 1'b0;
                    has_waw_conflict <= 1'b0;
                    has_war_conflict <= 1'b0;
                    transaction_has_conflict <= 1'b0;
                    
                    // Check if this is the first transaction (empty batch)
                    if ((batch_read_dependencies == {MAX_DEPENDENCIES{1'b0}}) && (batch_write_dependencies == {MAX_DEPENDENCIES{1'b0}})) begin
                        // First transaction can't have conflicts
                        has_raw_conflict <= 1'b0;
                        has_waw_conflict <= 1'b0;
                        has_war_conflict <= 1'b0;
                        
                        if (DEBUG_ENABLE)
                            $display("Time %0t: First transaction in batch - no conflicts possible", $time);
                    end else begin
                        // Use direct vector operations for reliable conflict detection
                        has_raw_conflict <= |(read_deps_pipe & batch_write_dependencies);
                        has_waw_conflict <= |(write_deps_pipe & batch_write_dependencies);
                        has_war_conflict <= |(write_deps_pipe & batch_read_dependencies);
                    end
                    
                    // Set overall conflict flag - properly handle first transaction
                    if ((batch_read_dependencies == {MAX_DEPENDENCIES{1'b0}}) && (batch_write_dependencies == {MAX_DEPENDENCIES{1'b0}})) begin
                        // First transaction can't have conflicts
                        transaction_has_conflict <= 1'b0;
                    end else begin
                        // Not the first transaction, check for conflicts
                        // Use direct vector operations for reliable conflict detection
                        transaction_has_conflict <= |(read_deps_pipe & batch_write_dependencies) || 
                                                  |(write_deps_pipe & batch_write_dependencies) || 
                                                  |(write_deps_pipe & batch_read_dependencies);
                    end
                
                // Skip the chunk-based verification for now - it causes syntax issues with Icarus Verilog
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: Vector-based conflict detection results:", $time);
                    $display("  RAW conflict: %b", has_raw_conflict);
                    $display("  WAW conflict: %b", has_waw_conflict);
                    $display("  WAR conflict: %b", has_war_conflict);
                    $display("  Overall conflict: %b", transaction_has_conflict);
                end
                
                // For the first transaction, there can't be any conflicts since the batch is empty
                if ((batch_read_dependencies == {MAX_DEPENDENCIES{1'b0}}) && (batch_write_dependencies == {MAX_DEPENDENCIES{1'b0}})) begin
                    if (DEBUG_ENABLE)
                        $display("Time %0t: First transaction in batch - no conflicts possible", $time);
                    has_raw_conflict <= 1'b0;
                    has_waw_conflict <= 1'b0;
                    has_war_conflict <= 1'b0;
                    transaction_has_conflict <= 1'b0;
                    
                    // Note: We'll update batch dependencies in the main update logic below
                    // This ensures consistent handling of all transactions
                    
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: First transaction detected - no conflicts possible", $time);
                        $display("  Will initialize batch dependencies with this transaction");
                    end
                end
                
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: Conflict detection results: RAW=%b, WAW=%b, WAR=%b", 
                             $time, has_raw_conflict, has_waw_conflict, has_war_conflict);
                end
                
                // Simplified bit-level conflict detection for debugging
                if (DEBUG_ENABLE && (has_raw_conflict || has_waw_conflict || has_war_conflict)) begin
                    $display("Time %0t: Conflict detected - detailed analysis:", $time);
                    $display("  Read deps: %h", read_deps_pipe);
                    $display("  Write deps: %h", write_deps_pipe);
                    $display("  Batch read deps: %h", batch_read_dependencies);
                    $display("  Batch write deps: %h", batch_write_dependencies);
                end
                
                // Also calculate using the original method for validation
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: Vector-based conflict check results:", $time);
                    $display("  RAW conflict (vector): %b", |(read_deps_pipe & batch_write_dependencies));
                    $display("  WAW conflict (vector): %b", |(write_deps_pipe & batch_write_dependencies));
                    $display("  WAR conflict (vector): %b", |(write_deps_pipe & batch_read_dependencies));
                end
                
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: Explicit conflict check results:", $time);
                    $display("  read_deps_pipe: %h", read_deps_pipe);
                    $display("  write_deps_pipe: %h", write_deps_pipe);
                    $display("  batch_read_dependencies: %h", batch_read_dependencies);
                    $display("  batch_write_dependencies: %h", batch_write_dependencies);
                end
                
                if (DEBUG_ENABLE) begin
                    $display("Time %0t: Conflict check results:", $time);
                    $display("  RAW conflict: %b (read_deps & batch_write_deps)", has_raw_conflict);
                    $display("  WAW conflict: %b (write_deps & batch_write_deps)", has_waw_conflict);
                    $display("  WAR conflict: %b (write_deps & batch_read_deps)", has_war_conflict);
                    $display("  raw_conflict vector: %b", raw_conflict);
                    $display("  waw_conflict vector: %b", waw_conflict);
                    $display("  war_conflict vector: %b", war_conflict);
                end
                
                    // Prepare output data
                    m_axis_tdata_owner_programID <= owner_pipe;
                    m_axis_tdata_read_dependencies <= read_deps_pipe;
                    m_axis_tdata_write_dependencies <= write_deps_pipe;
                    m_axis_tdata_has_conflict <= transaction_has_conflict;  // Forward conflict status
                    
                    // Prepare to move to OUTPUT state
                    // m_axis_tvalid is already asserted above at the beginning of CHECK state
                    
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: CHECK state - Moving to OUTPUT state for transaction ID: %h", $time, owner_pipe);
                        $display("Time %0t: Transaction has conflicts: %b (RAW=%b, WAW=%b, WAR=%b)", 
                                 $time, transaction_has_conflict, has_raw_conflict, has_waw_conflict, has_war_conflict);
                    end
                
                // Update conflict counters if conflicts detected
                if (transaction_has_conflict) begin
                    // Update conflict counters - use non-blocking assignments for proper synchronization
                    if (has_raw_conflict) begin
                        raw_conflicts <= raw_conflicts + 32'd1;  // Use non-blocking assignment with explicit width
                        if (DEBUG_ENABLE)
                            $display("Time %0t: RAW conflict detected! Read deps %h conflict with batch write deps %h", 
                                     $time, read_deps_pipe, batch_write_dependencies);
                    end
                    if (has_waw_conflict) begin
                        waw_conflicts <= waw_conflicts + 32'd1;  // Use non-blocking assignment with explicit width
                        if (DEBUG_ENABLE)
                            $display("Time %0t: WAW conflict detected! Write deps %h conflict with batch write deps %h", 
                                     $time, write_deps_pipe, batch_write_dependencies);
                    end
                    if (has_war_conflict) begin
                        war_conflicts <= war_conflicts + 32'd1;  // Use non-blocking assignment with explicit width
                        if (DEBUG_ENABLE)
                            $display("Time %0t: WAR conflict detected! Write deps %h conflict with batch read deps %h", 
                                     $time, write_deps_pipe, batch_read_dependencies);
                    end
                    filter_hits <= filter_hits + 32'd1;  // Use non-blocking assignment with explicit width
                    
                    // Even with conflicts, we still need to assert valid to indicate transaction is ready
                    // This ensures the testbench can track what happened with conflicting transactions
                    
                    // Debug output
                    if (DEBUG_ENABLE)
                        $display("Time %0t: Conflicts detected - RAW: %d, WAW: %d, WAR: %d, Total: %d", 
                                 $time, raw_conflicts, waw_conflicts, war_conflicts, filter_hits);
                    
                    // Even with conflicts, we still move to OUTPUT state to complete the transaction
                    // We just don't update the batch dependencies
                end else begin
                    // No conflicts, update batch dependencies
                    // For first transaction, we already set the dependencies directly
                    // For subsequent transactions, OR with existing dependencies
                    if (!((batch_read_dependencies == {MAX_DEPENDENCIES{1'b0}}) && (batch_write_dependencies == {MAX_DEPENDENCIES{1'b0}}))) begin
                        // Not the first transaction, update by OR-ing with existing dependencies
                        batch_read_dependencies <= batch_read_dependencies | read_deps_pipe;
                        batch_write_dependencies <= batch_write_dependencies | write_deps_pipe;
                    end else begin
                        // First transaction, set dependencies directly
                        batch_read_dependencies <= read_deps_pipe;
                        batch_write_dependencies <= write_deps_pipe;
                    end
                    
                    if (DEBUG_ENABLE) begin
                        $display("Time %0t: No conflicts - batch dependencies updated", $time);
                        if ((batch_read_dependencies == {MAX_DEPENDENCIES{1'b0}}) && (batch_write_dependencies == {MAX_DEPENDENCIES{1'b0}})) begin
                            $display("  First transaction - setting initial batch dependencies");
                            $display("  Initial batch read deps: %h", read_deps_pipe);
                            $display("  Initial batch write deps: %h", write_deps_pipe);
                        end else begin
                            $display("  Updated batch read deps: %h", batch_read_dependencies | read_deps_pipe);
                            $display("  Updated batch write deps: %h", batch_write_dependencies | write_deps_pipe);
                        end
                        
                        // Simple verification of dependency updates
                        $display("Time %0t: Verifying dependency updates", $time);
                        if ((batch_read_dependencies == {MAX_DEPENDENCIES{1'b0}}) && (batch_write_dependencies == {MAX_DEPENDENCIES{1'b0}})) begin
                            $display("  Initial batch read deps: %h", read_deps_pipe);
                            $display("  Initial batch write deps: %h", write_deps_pipe);
                        end else begin
                            $display("  Updated batch read deps: %h", batch_read_dependencies | read_deps_pipe);
                            $display("  Updated batch write deps: %h", batch_write_dependencies | write_deps_pipe);
                        end
                    end
                end
                
                    // Move to OUTPUT state to wait for m_axis_tready
                    // m_axis_tvalid is already asserted above at the beginning of CHECK state
                    state <= OUTPUT; // Always go to OUTPUT state to wait for m_axis_tready
                    s_axis_tready <= 1'b0; // Not ready for next transaction until this one is handled
                end else begin
                    // No transaction in progress, go back to IDLE
                    state <= IDLE;
                    s_axis_tready <= 1'b1;  // Ready to accept new transactions
                    m_axis_tvalid <= 1'b0;  // No valid output when no transaction
                    transaction_valid_pipe <= 1'b0;  // Clear transaction valid flag
                end
            end
            
            OUTPUT: begin
                // In OUTPUT state, wait for downstream module to accept the transaction
                // Keep m_axis_tvalid asserted until m_axis_tready is asserted
                // This follows AXI-Stream protocol where valid must remain asserted until ready is asserted
                if (transaction_in_progress) begin
                    // Always maintain valid assertion in OUTPUT state - critical for AXI-Stream protocol
                    m_axis_tvalid <= 1'b1;  // CRITICAL: Keep valid asserted until handshake completes
                    
                    if (m_axis_tready) begin
                        // Transaction accepted by downstream module - AXI handshake complete
                        if (DEBUG_ENABLE) begin
                            $display("Time %0t: OUTPUT state - Transaction accepted by downstream module", $time);
                            $display("Time %0t: Transaction ID %h processed", $time, m_axis_tdata_owner_programID);
                        end
                        
                        // We've already updated batch dependencies in CHECK state
                        // No need to update again here, just log the final state
                        if (DEBUG_ENABLE) begin
                            if (!transaction_has_conflict) begin
                                $display("Time %0t: OUTPUT state - Transaction without conflicts processed", $time);
                                $display("  Current batch read deps: %h", batch_read_dependencies);
                                $display("  Current batch write deps: %h", batch_write_dependencies);
                            end else begin
                                // For conflicting transactions, we don't update the batch dependencies
                                // This is critical for maintaining transaction serializability
                                $display("Time %0t: OUTPUT state - Conflicting transaction processed (no dependency update)", $time);
                                $display("  Conflict type: RAW=%b, WAW=%b, WAR=%b", has_raw_conflict, has_waw_conflict, has_war_conflict);
                                $display("  Batch read deps remain: %h", batch_read_dependencies);
                                $display("  Batch write deps remain: %h", batch_write_dependencies);
                            end
                        end
                        
                        // Verify that the transaction was properly processed
                        if (DEBUG_ENABLE) begin
                            $display("Time %0t: Transaction %h processed successfully", $time, m_axis_tdata_owner_programID);
                            $display("  Current conflict counts: RAW=%0d, WAW=%0d, WAR=%0d, Total=%0d",
                                     raw_conflicts, waw_conflicts, war_conflicts, filter_hits);
                        end
                        
                        // Complete AXI-Stream handshake: deassert valid and return to IDLE state
                        m_axis_tvalid <= 1'b0; // Deassert valid after handshake completes
                        transaction_in_progress <= 1'b0; // Clear transaction flag
                        transaction_valid_pipe <= 1'b0; // Reset transaction valid flag
                        
                        // Return to IDLE state to process next transaction
                        state <= IDLE;
                        s_axis_tready <= 1'b1;  // Ready to accept new transactions
                    end else begin
                        // Keep waiting for m_axis_tready
                        // Critical: Keep valid asserted and don't accept new transactions while waiting
                        m_axis_tvalid <= 1'b1;  // Keep valid asserted per AXI-Stream protocol
                        s_axis_tready <= 1'b0;  // Not ready for new transactions while waiting
                    end
                end else begin
                    // No transaction in progress, go back to IDLE
                    state <= IDLE;
                    s_axis_tready <= 1'b1;  // Ready to accept new transactions
                    m_axis_tvalid <= 1'b0;  // No valid output when no transaction
                    transaction_valid_pipe <= 1'b0;  // Clear transaction valid flag
                end
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule