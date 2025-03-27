`timescale 1ns / 1ps

//-----------------------------------------------------------------------------
// SVM Hardware Scheduler Testbench
//-----------------------------------------------------------------------------
// This testbench verifies the functionality of the SVM Hardware Scheduler,
// focusing on transaction processing, conflict detection, and performance.
//-----------------------------------------------------------------------------

module tb_svm_scheduler;

//-----------------------------------------------------------------------------
// Configuration Parameters
//-----------------------------------------------------------------------------

// Test configuration
parameter NUM_TEST_CASES = 500;     // Number of test cases to generate
parameter CONFLICT_INTERVAL = 5;    // Generate conflict every Nth transaction
parameter MAX_TIMEOUT_CYCLES = 2000; // Maximum cycles to wait for completion
parameter STALL_TIMEOUT = 500;      // Cycles before declaring system stalled
parameter PROGRESS_INTERVAL = 100;   // Display progress every N cycles

// Test pattern configuration
parameter NUM_TEST_SECTIONS = 7;    // Number of different test sections
parameter SECTION_SIZE = NUM_TEST_CASES / NUM_TEST_SECTIONS; // Size of each test section

// Debug configuration
parameter DEBUG_ENABLE = 1;          // Enable detailed debug output
parameter VERBOSE_DEBUG = 0;         // Enable very verbose debugging

// DUT configuration
parameter NUM_PARALLEL_INSTANCES = 4;   // Number of parallel instances
parameter MAX_DEPENDENCIES = 256;       // Dependency vector width
parameter MAX_BATCH_SIZE = 8;          // Maximum transactions per batch
parameter BATCH_TIMEOUT_CYCLES = 100;   // Cycles before batch timeout
parameter MAX_PENDING_TRANSACTIONS = 16; // Max pending transactions
parameter INSERTION_QUEUE_DEPTH = 8;     // Depth of insertion queue

//-----------------------------------------------------------------------------
// Performance Counters & Statistics
//-----------------------------------------------------------------------------

// Transaction counters
reg [31:0] test_case_counter;           // Number of test cases generated
reg [31:0] total_transactions_submitted; // Total transactions sent to DUT
reg [31:0] total_transactions_completed; // Total transactions completed
reg [31:0] total_transactions_conflicted; // Total individual conflicts
reg [31:0] unique_transactions_conflicted; // Unique transactions with conflicts

// Batch statistics
reg [31:0] total_batches;               // Total batches processed
reg [31:0] current_batch_size;          // Current batch size

// Performance metrics
reg [31:0] total_cycles;                // Total simulation cycles

// Conflict type tracking
reg [31:0] tracked_raw_conflicts;        // Read-After-Write conflicts
reg [31:0] tracked_waw_conflicts;        // Write-After-Write conflicts
reg [31:0] tracked_war_conflicts;        // Write-After-Read conflicts

//-----------------------------------------------------------------------------
// Interface Signals
//-----------------------------------------------------------------------------

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

//-----------------------------------------------------------------------------
// DUT Instantiation
//-----------------------------------------------------------------------------

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

//-----------------------------------------------------------------------------
// Clock Generation
//-----------------------------------------------------------------------------

initial begin
    clk = 0;
    forever #5 clk = ~clk; // 100MHz clock (10ns period)
end

//-----------------------------------------------------------------------------
// Performance Monitoring
//-----------------------------------------------------------------------------

always @(posedge clk) begin
    if (!rst_n) begin
        if (!initial_reset_done) begin
            // Only reset counters on the initial reset, not on forced resets
            total_transactions_submitted <= 0;
            total_transactions_completed <= 0;
            total_transactions_conflicted <= 0;
            unique_transactions_conflicted <= 0;
            total_batches <= 0;
            current_batch_size <= 0;
            total_cycles <= 0;
            tracked_raw_conflicts <= 0;
            tracked_waw_conflicts <= 0;
            tracked_war_conflicts <= 0;
            initial_reset_done <= 1;
        end
    end else begin
        // Increment cycle counter
        total_cycles <= total_cycles + 1;
        
        // Count submitted transactions - only count from test generator
        if (s_axis_tvalid && s_axis_tready && test_case_counter < NUM_TEST_CASES) begin
            total_transactions_submitted <= test_case_counter + 1;
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
        
        // Track conflict types
        if (dut.cm_inst.raw_conflict_count > tracked_raw_conflicts) begin
            tracked_raw_conflicts <= dut.cm_inst.raw_conflict_count;
        end
        if (dut.cm_inst.waw_conflict_count > tracked_waw_conflicts) begin
            tracked_waw_conflicts <= dut.cm_inst.waw_conflict_count;
        end
        if (dut.cm_inst.war_conflict_count > tracked_war_conflicts) begin
            tracked_war_conflicts <= dut.cm_inst.war_conflict_count;
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

//-----------------------------------------------------------------------------
// Test Pattern Definitions
//-----------------------------------------------------------------------------

// Enum for different test pattern types
typedef enum {
    PATTERN_NORMAL,           // No conflicts
    PATTERN_WAW_CONFLICT,     // Write-After-Write conflicts
    PATTERN_RAW_CONFLICT,     // Read-After-Write conflicts
    PATTERN_WAR_CONFLICT,     // Write-After-Read conflicts
    PATTERN_MIXED_CONFLICT,   // Mix of different conflict types
    PATTERN_BURST,            // Burst of transactions without waiting
    PATTERN_SPARSE            // Sparse transactions with delays
} test_pattern_t;

// Task to generate a transaction with specific dependency patterns
task generate_transaction;
    input [63:0] transaction_id;
    input [2:0] pattern_type;  // Using test_pattern_t enum
    begin
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk); // Wait for ready signal
        
        // Set transaction data
        s_axis_tvalid = 1;
        s_axis_tdata_owner_programID = transaction_id;
        
        case (pattern_type)
            PATTERN_NORMAL: begin
                // Normal transaction without conflicts
                s_axis_tdata_read_dependencies = 32'h0000_FF00; // Read from middle 8 bits
                s_axis_tdata_write_dependencies = 32'hFF00_0000; // Write to upper 8 bits
                if (VERBOSE_DEBUG) $display("Creating normal transaction: %0d", transaction_id);
            end
            
            PATTERN_WAW_CONFLICT: begin
                // Create a write-after-write conflict pattern
                s_axis_tdata_read_dependencies = 0;
                s_axis_tdata_write_dependencies = 32'h0000_00FF; // Write to first 8 bits
                if (VERBOSE_DEBUG) $display("Creating WAW conflict transaction: %0d", transaction_id);
            end
            
            PATTERN_RAW_CONFLICT: begin
                // Create a read-after-write conflict pattern
                s_axis_tdata_read_dependencies = 32'h0000_00FF; // Read from first 8 bits
                s_axis_tdata_write_dependencies = 32'h0000_FF00; // Write to middle 8 bits
                if (VERBOSE_DEBUG) $display("Creating RAW conflict transaction: %0d", transaction_id);
            end
            
            PATTERN_WAR_CONFLICT: begin
                // Create a write-after-read conflict pattern
                s_axis_tdata_read_dependencies = 32'h0000_FF00; // Read from middle 8 bits
                s_axis_tdata_write_dependencies = 32'h0000_FF00; // Write to same middle 8 bits
                if (VERBOSE_DEBUG) $display("Creating WAR conflict transaction: %0d", transaction_id);
            end
            
            PATTERN_MIXED_CONFLICT: begin
                // Create a mix of conflicts based on transaction ID
                s_axis_tdata_read_dependencies = 32'h0000_FFFF >> (transaction_id % 8);
                s_axis_tdata_write_dependencies = 32'h00FF_0000 >> (transaction_id % 4);
                if (VERBOSE_DEBUG) $display("Creating mixed conflict transaction: %0d", transaction_id);
            end
            
            PATTERN_BURST: begin
                // Create a burst transaction with varying dependencies
                s_axis_tdata_read_dependencies = 32'h0000_0001 << (transaction_id % 16);
                s_axis_tdata_write_dependencies = 32'h0001_0000 << (transaction_id % 16);
                if (VERBOSE_DEBUG) $display("Creating burst transaction: %0d", transaction_id);
            end
            
            PATTERN_SPARSE: begin
                // Create sparse transaction with minimal dependencies
                s_axis_tdata_read_dependencies = 32'h0000_0001 << (transaction_id % 32);
                s_axis_tdata_write_dependencies = 32'h0000_0001 << ((transaction_id + 16) % 32);
                if (VERBOSE_DEBUG) $display("Creating sparse transaction: %0d", transaction_id);
            end
            
            default: begin
                // Default to normal transaction
                s_axis_tdata_read_dependencies = 32'h0000_FF00;
                s_axis_tdata_write_dependencies = 32'hFF00_0000;
            end
        endcase
        
        @(posedge clk);
        s_axis_tvalid = 0;
    end
endtask

// Task to insert a delay between transactions
task insert_delay;
    input [7:0] cycles;
    begin
        repeat(cycles) @(posedge clk);
    end
endtask

// Task to display progress information
task display_progress;
    input [31:0] current;
    input [31:0] total;
    begin
        $display("\nProgress: %0d/%0d transactions (%0d%%)", 
                 current, total, (current * 100) / total);
        $display("  Submitted:  %0d", total_transactions_submitted);
        $display("  Completed:  %0d", total_transactions_completed);
        $display("  Conflicted: %0d", total_transactions_conflicted);
        $display("  Batches:    %0d", total_batches);
    end
endtask

// Task to calculate and display in-flight transactions
task display_in_flight;
    output [31:0] in_flight;
    begin
        // Calculate in-flight transactions safely
        in_flight = (total_transactions_completed + unique_transactions_conflicted <= total_transactions_submitted) ? 
                  (total_transactions_submitted - total_transactions_completed - unique_transactions_conflicted) : 0;
        $display("  In-flight:  %0d", in_flight);
    end
endtask

//-----------------------------------------------------------------------------
// Test Stimulus
//-----------------------------------------------------------------------------

reg initial_reset_done = 0; // Track initial vs forced resets

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
    
    // Use the test pattern configuration parameters defined at module level
    
    // Generate test patterns
    $display("Starting test pattern generation for %d test cases across %d test sections...", 
             NUM_TEST_CASES, NUM_TEST_SECTIONS);
    
    //-------------------------------------------------------------------------
    // Section 1: Normal transactions (no conflicts)
    //-------------------------------------------------------------------------
    $display("\nSection 1: Normal transactions (no conflicts)");
    for (test_case_counter = 0; test_case_counter < SECTION_SIZE; test_case_counter++) begin
        generate_transaction(test_case_counter, PATTERN_NORMAL);
        
        // Progress reporting
        if (test_case_counter % PROGRESS_INTERVAL == 0 && test_case_counter > 0) begin
            display_progress(test_case_counter, SECTION_SIZE);
        end
    end
    
    //-------------------------------------------------------------------------
    // Section 2: Write-After-Write (WAW) conflicts
    //-------------------------------------------------------------------------
    $display("\nSection 2: Write-After-Write (WAW) conflicts");
    for (integer i = 0; i < SECTION_SIZE; i++) begin
        // Every 3rd transaction has WAW conflict potential
        test_case_counter = SECTION_SIZE + i;
        generate_transaction(test_case_counter, 
                           (i % 3 == 0) ? PATTERN_WAW_CONFLICT : PATTERN_NORMAL);
        
        // Progress reporting
        if (i % PROGRESS_INTERVAL == 0 && i > 0) begin
            display_progress(i, SECTION_SIZE);
        end
    end
    
    //-------------------------------------------------------------------------
    // Section 3: Read-After-Write (RAW) conflicts
    //-------------------------------------------------------------------------
    $display("\nSection 3: Read-After-Write (RAW) conflicts");
    for (integer i = 0; i < SECTION_SIZE; i++) begin
        // Every 4th transaction has RAW conflict potential
        test_case_counter = 2 * SECTION_SIZE + i;
        generate_transaction(test_case_counter, 
                           (i % 4 == 0) ? PATTERN_RAW_CONFLICT : PATTERN_NORMAL);
        
        // Progress reporting
        if (i % PROGRESS_INTERVAL == 0 && i > 0) begin
            display_progress(i, SECTION_SIZE);
        end
    end
    
    //-------------------------------------------------------------------------
    // Section 4: Write-After-Read (WAR) conflicts
    //-------------------------------------------------------------------------
    $display("\nSection 4: Write-After-Read (WAR) conflicts");
    for (integer i = 0; i < SECTION_SIZE; i++) begin
        // Every 5th transaction has WAR conflict potential
        test_case_counter = 3 * SECTION_SIZE + i;
        generate_transaction(test_case_counter, 
                           (i % 5 == 0) ? PATTERN_WAR_CONFLICT : PATTERN_NORMAL);
        
        // Progress reporting
        if (i % PROGRESS_INTERVAL == 0 && i > 0) begin
            display_progress(i, SECTION_SIZE);
        end
    end
    
    //-------------------------------------------------------------------------
    // Section 5: Mixed conflict patterns
    //-------------------------------------------------------------------------
    $display("\nSection 5: Mixed conflict patterns");
    for (integer i = 0; i < SECTION_SIZE; i++) begin
        test_case_counter = 4 * SECTION_SIZE + i;
        // Rotate through different conflict patterns
        case (i % 5)
            0: generate_transaction(test_case_counter, PATTERN_WAW_CONFLICT);
            1: generate_transaction(test_case_counter, PATTERN_RAW_CONFLICT);
            2: generate_transaction(test_case_counter, PATTERN_WAR_CONFLICT);
            3: generate_transaction(test_case_counter, PATTERN_MIXED_CONFLICT);
            4: generate_transaction(test_case_counter, PATTERN_NORMAL);
        endcase
        
        // Progress reporting
        if (i % PROGRESS_INTERVAL == 0 && i > 0) begin
            display_progress(i, SECTION_SIZE);
        end
    end
    
    //-------------------------------------------------------------------------
    // Section 6: Burst transactions (rapid submission)
    //-------------------------------------------------------------------------
    $display("\nSection 6: Burst transactions");
    for (integer i = 0; i < SECTION_SIZE; i++) begin
        test_case_counter = 5 * SECTION_SIZE + i;
        // Burst transactions with minimal delay
        generate_transaction(test_case_counter, PATTERN_BURST);
        // No delay between transactions to stress the system
        
        // Progress reporting
        if (i % PROGRESS_INTERVAL == 0 && i > 0) begin
            display_progress(i, SECTION_SIZE);
        end
    end
    
    //-------------------------------------------------------------------------
    // Section 7: Sparse transactions (with delays)
    //-------------------------------------------------------------------------
    $display("\nSection 7: Sparse transactions with delays");
    for (integer i = 0; i < SECTION_SIZE; i++) begin
        test_case_counter = 6 * SECTION_SIZE + i;
        generate_transaction(test_case_counter, PATTERN_SPARSE);
        
        // Add variable delays between transactions
        if (i % 10 == 0) begin
            insert_delay(5);  // 5-cycle delay every 10 transactions
        end
        
        // Progress reporting
        if (i % PROGRESS_INTERVAL == 0 && i > 0) begin
            display_progress(i, SECTION_SIZE);
        end
    end
    
    // Handle any remaining transactions to reach NUM_TEST_CASES
    for (integer i = 7 * SECTION_SIZE; i < NUM_TEST_CASES; i++) begin
        test_case_counter = i;
        generate_transaction(test_case_counter, PATTERN_NORMAL);
    end
    
    // Ensure total_transactions_submitted is set to the exact number of test cases
    total_transactions_submitted = NUM_TEST_CASES;
    
    // Report completion of test generation phase
    if (test_case_counter == NUM_TEST_CASES) begin
        $display("\nAll %0d test cases generated successfully", NUM_TEST_CASES);
        display_progress(test_case_counter, NUM_TEST_CASES);
    end else begin
        $display("\nWARNING: Only %0d/%0d test cases were generated", test_case_counter, NUM_TEST_CASES);
    end
    
    //-------------------------------------------------------------------------
    // Wait for completion or timeout
    //-------------------------------------------------------------------------
    
    begin
        // Local variables for completion monitoring
        reg done;
        integer timeout_counter;
        integer stall_counter;
        integer prev_completed;
        integer prev_conflicted;
        integer in_flight;
        
        // Monitor completion with timeout
        while (!done && timeout_counter < MAX_TIMEOUT_CYCLES) begin
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
            if (timeout_counter % PROGRESS_INTERVAL == 0) begin
                $display("\nWaiting for completion... %0d cycles (stalled for %0d cycles)", 
                         timeout_counter, stall_counter);
                $display("  Completed:  %0d", total_transactions_completed);
                $display("  Conflicted: %0d", total_transactions_conflicted);
                
                // Calculate unique conflicted transactions
                unique_transactions_conflicted = total_transactions_submitted - total_transactions_completed;
                $display("  Unique Conflicted: %0d", unique_transactions_conflicted);
                
                // Display in-flight transactions
                display_in_flight(in_flight);
                
                // Check active batches
                $display("\nActive Batches:");
                $display("  Current batch size: %0d", dut.total_current_batch_size);
            end
            
            // Check completion conditions
            if (total_transactions_completed + unique_transactions_conflicted >= total_transactions_submitted) begin
                done = 1;
            end
            
            // If stalled for too long, force a reset
            if (stall_counter >= STALL_TIMEOUT) begin
                $display("\nWARNING: System stalled for %0d cycles - forcing reset", stall_counter);
                
                // Force reset but keep the statistics values
                rst_n = 0;
                repeat(5) @(posedge clk);
                rst_n = 1;
                done = 1;
            end
        end
        
        // Handle timeout case
        if (timeout_counter >= MAX_TIMEOUT_CYCLES) begin
            $display("\nWARNING: Simulation timed out after %0d cycles with transactions still in-flight!", 
                     MAX_TIMEOUT_CYCLES);
            $display("  Last known state:");
            $display("    Current batch size: %0d", dut.total_current_batch_size);
            $display("    Transactions in batch: %0d", dut.total_transactions_in_batch);
        end
    end
    
    //-------------------------------------------------------------------------
    // Final Statistics Report
    //-------------------------------------------------------------------------
    
    // Calculate unique conflicted transactions for final report
    unique_transactions_conflicted = total_transactions_submitted - total_transactions_completed;
    
    // Display header
    $display("\nTest completed! Final Statistics:");
    $display("----------------------------------------");
    
    // Transaction statistics
    $display("Total Transactions:");
    $display("  Submitted:  %0d", total_transactions_submitted);
    $display("  Completed:  %0d", total_transactions_completed);
    $display("  Conflicted: %0d (individual conflicts)", total_transactions_conflicted);
    $display("  Unique Conflicted: %0d (%.2f%%)", 
             unique_transactions_conflicted,
             total_transactions_submitted > 0 ? 
             (unique_transactions_conflicted * 100.0 / total_transactions_submitted) : 0);
    
    // Calculate in-flight transactions for final report
    begin
        integer final_in_flight;
        display_in_flight(final_in_flight);
    end
    
    // Batch statistics
    $display("\nBatch Statistics:");
    $display("  Total batches:     %0d", total_batches);
    $display("  Avg batch size:    %.2f", 
             total_batches > 0 ? (total_transactions_completed * 1.0 / total_batches) : 0);
    
    // Conflict analysis
    $display("\nConflict Analysis:");
    $display("  RAW conflicts: %0d", tracked_raw_conflicts);
    $display("  WAW conflicts: %0d", tracked_waw_conflicts);
    $display("  WAR conflicts: %0d", tracked_war_conflicts);
    $display("  Total conflicts: %0d", total_transactions_conflicted);
    
    // Performance metrics
    $display("\nPerformance Metrics:");
    $display("  Total simulation cycles: %0d", total_cycles);
    $display("  Transactions processed per cycle: %.3f", total_transactions_submitted * 1.0 / total_cycles);
    $display("  Transactions completed per cycle: %.3f", total_transactions_completed * 1.0 / total_cycles);
    $display("  Cycles per transaction: %.2f", total_cycles * 1.0 / total_transactions_submitted);
    $display("  Cycles per completed transaction: %.2f", total_cycles * 1.0 / total_transactions_completed);
    $display("  Txns submitted: %.2f M/s", total_transactions_submitted * 1.0 / (total_cycles * 1.0 / 1000000000) / 1000000);
    $display("  Txns completed: %.2f M/s", total_transactions_completed * 1.0 / (total_cycles * 1.0 / 1000000000) / 1000000);
    $display("----------------------------------------");
    
    $finish;
end

endmodule