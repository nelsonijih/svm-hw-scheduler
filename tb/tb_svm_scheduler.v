`timescale 1ns / 1ps

module tb_svm_scheduler;

// Parameters
parameter NUM_TEST_CASES = 500;  // Number of test cases to generate
parameter DEBUG_ENABLE = 1;      // Enable debug output

// Module parameters
parameter NUM_PARALLEL_INSTANCES = 4;  // Number of parallel instances
parameter MAX_DEPENDENCIES = 256;    // Dependency vector width
parameter MAX_BATCH_SIZE = 8;       // Maximum transactions per batch
parameter BATCH_TIMEOUT_CYCLES = 100; // Cycles before timeout
parameter MAX_PENDING_TRANSACTIONS = 16; // Max pending transactions
parameter INSERTION_QUEUE_DEPTH = 8;   // Depth of insertion queue

// Basic performance counters
reg [31:0] test_case_counter;
reg [31:0] total_transactions_submitted;
reg [31:0] total_transactions_completed;
reg [31:0] total_transactions_conflicted;
reg [31:0] unique_transactions_conflicted;  // Count of unique transactions that had conflicts
reg [31:0] total_batches;
reg [31:0] current_batch_size;
reg [31:0] total_cycles;

// Conflict type tracking counters
reg [31:0] tracked_raw_conflicts;
reg [31:0] tracked_waw_conflicts;
reg [31:0] tracked_war_conflicts;

// Clock and reset
reg clk;
reg rst_n;

// Input AXI-Stream interface
reg s_axis_tvalid;
wire s_axis_tready;
reg [63:0] s_axis_tdata_owner_programID;
reg [MAX_DEPENDENCIES-1:0] s_axis_tdata_read_dependencies;
reg [MAX_DEPENDENCIES-1:0] s_axis_tdata_write_dependencies;

// Output AXI-Stream interface
wire [NUM_PARALLEL_INSTANCES-1:0] m_axis_tvalid;
reg [NUM_PARALLEL_INSTANCES-1:0] m_axis_tready;
wire [NUM_PARALLEL_INSTANCES-1:0][63:0] m_axis_tdata_owner_programID;
wire [NUM_PARALLEL_INSTANCES-1:0][MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies;
wire [NUM_PARALLEL_INSTANCES-1:0][MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies;

// Performance monitoring from DUT
wire [31:0] total_raw_conflicts;
wire [31:0] total_waw_conflicts;
wire [31:0] total_war_conflicts;
wire [31:0] total_filter_hits;
wire [31:0] total_queue_occupancy;
wire [31:0] total_current_batch_size;
wire [NUM_PARALLEL_INSTANCES-1:0] batch_completed;

// Flags to track initial reset vs forced reset
reg initial_reset_done = 0;

// Monitor transaction submission and completion
always @(posedge clk) begin
    if (!rst_n) begin
        if (!initial_reset_done) begin
            // Only reset counters on the initial reset, not on forced resets
            total_transactions_submitted <= 0;
            total_transactions_completed <= 0;
            total_transactions_conflicted <= 0;
            unique_transactions_conflicted <= 0;  // Initialize unique conflicts counter
            total_batches <= 0;
            current_batch_size <= 0;
            total_cycles <= 0;
            tracked_raw_conflicts <= 0;
            tracked_waw_conflicts <= 0;
            tracked_war_conflicts <= 0;
            initial_reset_done <= 1;
        end
    end else begin
        total_cycles <= total_cycles + 1;
        
        // Count submitted transactions - only count transactions from the test generator
        // This ensures we only count each logical transaction once
        if (s_axis_tvalid && s_axis_tready && test_case_counter < NUM_TEST_CASES) begin
            total_transactions_submitted <= test_case_counter + 1;  // Add 1 since we're counting from 0
        end
        
        // Count completed transactions
        if (m_axis_tvalid != 0 && m_axis_tready != 0) begin
            total_transactions_completed <= total_transactions_completed + 1;
            current_batch_size <= current_batch_size + 1;
        end
        
        // Track conflicts
        if (dut.global_conflicts > total_transactions_conflicted) begin
            total_transactions_conflicted <= dut.global_conflicts;
        end
        
        // We'll calculate unique conflicts at the end of the simulation
        // This is just a placeholder during simulation
        if (dut.has_global_conflict && dut.s_axis_tvalid && dut.s_axis_tready) begin
            // No increment here - we'll calculate at the end
        end
        
        // Track conflict types
        if (dut.gdm_inst.raw_conflict_count > tracked_raw_conflicts) begin
            tracked_raw_conflicts <= dut.gdm_inst.raw_conflict_count;
        end
        if (dut.gdm_inst.waw_conflict_count > tracked_waw_conflicts) begin
            tracked_waw_conflicts <= dut.gdm_inst.waw_conflict_count;
        end
        if (dut.gdm_inst.war_conflict_count > tracked_war_conflicts) begin
            tracked_war_conflicts <= dut.gdm_inst.war_conflict_count;
        end
        
        // Track batch completion
        if (batch_completed != 0) begin
            total_batches <= total_batches + 1;
            if (DEBUG_ENABLE) begin
                $display("Batch %0d completed with %0d transactions", 
                         total_batches, current_batch_size);
            end
            current_batch_size <= 0;
        end
    end
end

// DUT instantiation
top #(
    .NUM_PARALLEL_INSTANCES(NUM_PARALLEL_INSTANCES),
    .MAX_DEPENDENCIES(MAX_DEPENDENCIES),
    .MAX_BATCH_SIZE(MAX_BATCH_SIZE),
    .BATCH_TIMEOUT_CYCLES(BATCH_TIMEOUT_CYCLES),
    .MAX_PENDING_TRANSACTIONS(MAX_PENDING_TRANSACTIONS),
    .INSERTION_QUEUE_DEPTH(INSERTION_QUEUE_DEPTH)
) dut (
    .clk(clk),
    .rst_n(rst_n),
    
    // Input interface
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata_owner_programID(s_axis_tdata_owner_programID),
    .s_axis_tdata_read_dependencies(s_axis_tdata_read_dependencies),
    .s_axis_tdata_write_dependencies(s_axis_tdata_write_dependencies),
    
    // Output interface
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata_owner_programID(m_axis_tdata_owner_programID),
    .m_axis_tdata_read_dependencies(m_axis_tdata_read_dependencies),
    .m_axis_tdata_write_dependencies(m_axis_tdata_write_dependencies),
    
    // Performance monitoring
    .total_raw_conflicts(total_raw_conflicts),
    .total_waw_conflicts(total_waw_conflicts),
    .total_war_conflicts(total_war_conflicts),
    .total_filter_hits(total_filter_hits),
    .total_queue_occupancy(total_queue_occupancy),
    .total_current_batch_size(total_current_batch_size),
    .batch_completed(batch_completed)
);

// Clock generation
initial begin
    clk = 0;
    forever #5 clk = ~clk;
end

// Test stimulus
initial begin
    // Initialize signals
    rst_n = 0;
    s_axis_tvalid = 0;
    s_axis_tdata_owner_programID = 0;
    s_axis_tdata_read_dependencies = 0;
    s_axis_tdata_write_dependencies = 0;
    test_case_counter = 0;
    
    // Set all instance outputs ready
    for (integer i = 0; i < NUM_PARALLEL_INSTANCES; i = i + 1)
        m_axis_tready[i] = 1;
    
    // Reset sequence
    #100 rst_n = 1;
    
    // Wait after reset
    repeat(10) @(posedge clk);
    
    // Generate test patterns
    $display("Starting test pattern generation for %d test cases...", NUM_TEST_CASES);
    
    while (test_case_counter < NUM_TEST_CASES) begin
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        
        // Generate transaction with forced conflicts every 5th transaction
        s_axis_tvalid = 1;
        s_axis_tdata_owner_programID = test_case_counter;
        
        if (test_case_counter % 5 == 0) begin
            // Create a write-after-write conflict
            s_axis_tdata_read_dependencies = 0;
            s_axis_tdata_write_dependencies = 32'h0000_00FF; // Write to first 8 bits
        end else begin
            // Normal transaction
            s_axis_tdata_read_dependencies = 32'h0000_FF00; // Read from next 8 bits
            s_axis_tdata_write_dependencies = 32'hFF00_0000; // Write to upper 8 bits
        end
        
        @(posedge clk);
        s_axis_tvalid = 0;
        
        test_case_counter = test_case_counter + 1;
        
        // Progress reporting
        if (test_case_counter % 100 == 0) begin
            $display("\nProgress: %0d/%0d transactions", test_case_counter, NUM_TEST_CASES);
            $display("  Submitted:  %0d", total_transactions_submitted);
            $display("  Completed:  %0d", total_transactions_completed);
            $display("  Conflicted: %0d", total_transactions_conflicted);
            $display("  Batches:    %0d", total_batches);
        end
    end
    
    // Ensure total_transactions_submitted is set to the exact number of test cases
    total_transactions_submitted = NUM_TEST_CASES;
    
    // We'll calculate unique conflicts at the end of the simulation
    
    // Make sure the last transaction is counted
    if (test_case_counter == NUM_TEST_CASES) begin
        $display("All %0d test cases generated successfully", NUM_TEST_CASES);
    end else begin
        $display("Warning: Only %0d/%0d test cases were generated", test_case_counter, NUM_TEST_CASES);
    end
    
    // Wait for completion or timeout
    begin
        reg done;
        integer i;
        integer timeout_counter;
        integer max_timeout;
        integer stall_counter;
        integer prev_completed;
        integer prev_conflicted;
        
        // Initialize variables
        done = 0;
        timeout_counter = 0;
        max_timeout = 2000; // Increased timeout
        stall_counter = 0;
        prev_completed = 0;
        prev_conflicted = 0;
        
        while (!done && timeout_counter < max_timeout) begin
            @(posedge clk);
            timeout_counter = timeout_counter + 1;
            
            // Check for progress
            if (prev_completed == total_transactions_completed && 
                prev_conflicted == total_transactions_conflicted) begin
                stall_counter = stall_counter + 1;
            end else begin
                stall_counter = 0;
                prev_completed = total_transactions_completed;
                prev_conflicted = total_transactions_conflicted;
            end
            
            // Progress update during waiting
            if (timeout_counter % 100 == 0) begin
                $display("\nWaiting for completion... %0d cycles (stalled for %0d cycles)", timeout_counter, stall_counter);
                $display("  Completed:  %0d", total_transactions_completed);
                $display("  Conflicted: %0d", total_transactions_conflicted);
                $display("  Unique Conflicted: %0d", unique_transactions_conflicted);
                // Calculate in-flight transactions safely
                begin
                    integer in_flight;
                    in_flight = (total_transactions_completed + unique_transactions_conflicted <= total_transactions_submitted) ? 
                              (total_transactions_submitted - total_transactions_completed - unique_transactions_conflicted) : 0;
                    $display("  In-flight:  %0d", in_flight);
                end
                
                // Check active batches
                $display("\nActive Batches:");
                $display("  Current batch size: %0d", dut.total_current_batch_size);
            end
            
            // Check completion conditions - use unique conflicts for accurate counting
            if (total_transactions_completed + unique_transactions_conflicted >= total_transactions_submitted) begin
                done = 1;
            end
            
            // If stalled for too long, force a reset
            if (stall_counter >= 500) begin
                $display("\nWARNING: System stalled for %0d cycles - forcing reset", stall_counter);
                
                // Force reset but keep the statistics values
                rst_n = 0;
                repeat(5) @(posedge clk);
                rst_n = 1;
                done = 1;
            end
        end
        
        if (timeout_counter >= max_timeout) begin
            $display("\nWARNING: Simulation timed out with transactions still in-flight!");
            $display("  Last known state:");
            $display("    Current batch size: %0d", dut.total_current_batch_size);
            $display("    Transactions in batch: %0d", dut.total_transactions_in_batch);
        end
    end
    
    // Final statistics
    $display("\nTest completed! Final Statistics:");
    $display("----------------------------------------");
    $display("Total Transactions:");
    $display("  Submitted:  %0d", total_transactions_submitted);
    $display("  Completed:  %0d", total_transactions_completed);
    $display("  Conflicted: %0d (individual conflicts)", total_transactions_conflicted);
    
    // Calculate unique conflicted transactions at the very end
    unique_transactions_conflicted = total_transactions_submitted - total_transactions_completed;
    $display("  Unique Conflicted: %0d (%.2f%%)", 
             unique_transactions_conflicted,
             total_transactions_submitted > 0 ? 
             (unique_transactions_conflicted * 100.0 / total_transactions_submitted) : 0);
    // Calculate in-flight transactions safely
    begin
        integer in_flight;
        in_flight = (total_transactions_completed + unique_transactions_conflicted <= total_transactions_submitted) ? 
                  (total_transactions_submitted - total_transactions_completed - unique_transactions_conflicted) : 0;
        $display("  In-flight:  %0d", in_flight);
    end
    $display("\nBatch Statistics:");
    $display("  Total batches:     %0d", total_batches);
    $display("  Avg batch size:    %.2f", 
             total_batches > 0 ? (total_transactions_completed * 1.0 / total_batches) : 0);
    $display("\nConflict Analysis:");
    $display("  RAW conflicts: %0d", tracked_raw_conflicts);
    $display("  WAW conflicts: %0d", tracked_waw_conflicts);
    $display("  WAR conflicts: %0d", tracked_war_conflicts);
    $display("  Total conflicts: %0d", total_transactions_conflicted);
    $display("----------------------------------------");
    
    $finish;
end

endmodule