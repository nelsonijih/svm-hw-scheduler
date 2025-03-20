`timescale 1ns / 1ps

module tb_svm_scheduler;

// Parameters
parameter DEBUG_ENABLE = 1;  // Enable debug output
parameter NUM_TEST_CASES = 500;  // Number of test cases to generate
parameter NUM_PARALLEL_CHECKS = 4;   // Number of parallel conflict checkers
parameter CHUNK_SIZE = MAX_DEPENDENCIES/NUM_PARALLEL_CHECKS; // Size of each chunk for parallel processing
parameter PATTERN_TYPES = 8;  // Different types of access patterns

// Test pattern generation parameters
reg [31:0] test_case_counter;
reg [2:0] pattern_type;  // Current pattern type being tested

// Conflict combination counters
reg [31:0] raw_only_conflicts;
reg [31:0] waw_only_conflicts;
reg [31:0] war_only_conflicts;
reg [31:0] raw_waw_conflicts;
reg [31:0] raw_war_conflicts;
reg [31:0] waw_war_conflicts;
reg [31:0] raw_waw_war_conflicts;

// Conflict detection signals
reg has_raw;
reg has_waw;
reg has_war;

// Previous conflict counters for edge detection
reg [31:0] prev_raw_conflicts;
reg [31:0] prev_waw_conflicts;
reg [31:0] prev_war_conflicts;
localparam MAX_DEPENDENCIES = 256;        // Full dependency vector width
localparam MAX_BATCH_SIZE = 8;            // Maximum transactions per batch
localparam MIN_BATCH_SIZE = 2;            // Minimum transactions before timeout
localparam BATCH_TIMEOUT_CYCLES = 100;     // Cycles before forcing batch output
localparam MAX_PENDING_TRANSACTIONS = 16;  // Maximum pending transactions
localparam INSERTION_QUEUE_DEPTH = 8;      // Depth of insertion queue

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
wire m_axis_tvalid;
reg m_axis_tready;
wire [63:0] m_axis_tdata_owner_programID;
wire [MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies;
wire [MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies;

// Performance monitoring from DUT
wire [31:0] raw_conflicts;
wire [31:0] waw_conflicts;
wire [31:0] war_conflicts;
wire [31:0] filter_hits;
wire [31:0] queue_occupancy;
wire [31:0] transactions_processed;
wire [31:0] transactions_batched;

// Testbench performance counters
reg [31:0] total_transactions_submitted;
reg [31:0] total_transactions_conflicted;
reg [31:0] total_transactions_batched;
reg [31:0] total_transactions_in_batch;  // Track transactions in current batch
reg [31:0] total_cycles;
reg [31:0] total_batches;
reg [31:0] current_batch_size;
reg [31:0] max_batch_size_seen;
reg [31:0] min_batch_size_seen;
real avg_batch_size;

// Latency tracking
reg [63:0] transaction_submit_time [31:0];  // Time when each transaction was submitted
reg [63:0] transaction_complete_time [31:0]; // Time when each transaction completed
real avg_transaction_latency;
real min_transaction_latency;
real max_transaction_latency;

// Batch timing
reg [63:0] batch_start_time;
reg [63:0] batch_complete_time;
real avg_batch_formation_time;
real min_batch_formation_time;
real max_batch_formation_time;

// Performance metrics
real simulation_time_ns;
real transactions_per_cycle;
real transactions_per_second;
real throughput_gbps;  // Based on 64-bit transactions

// Monitor transaction submission and completion
always @(posedge clk) begin
    if (!rst_n) begin
        total_transactions_submitted <= 0;
        total_transactions_conflicted <= 0;
        total_transactions_batched <= 0;
        total_transactions_in_batch <= 0;
        total_batches <= 0;
        current_batch_size <= 0;
        max_batch_size_seen <= 0;
        min_batch_size_seen <= 32'hFFFFFFFF;
        batch_start_time <= 0;
        
        // Reset conflict combination counters
        raw_only_conflicts <= 0;
        waw_only_conflicts <= 0;
        war_only_conflicts <= 0;
        raw_waw_conflicts <= 0;
        raw_war_conflicts <= 0;
        waw_war_conflicts <= 0;
        raw_waw_war_conflicts <= 0;
        
        // Reset previous conflict counters
        prev_raw_conflicts <= 0;
        prev_waw_conflicts <= 0;
        prev_war_conflicts <= 0;
    end else begin
        // Count submitted transactions and record submission time
        if (s_axis_tvalid && s_axis_tready) begin
            total_transactions_submitted <= total_transactions_submitted + 1;
            transaction_submit_time[total_transactions_submitted] <= $time;
        end
            
        // Track conflict statistics
        total_transactions_conflicted <= filter_hits;
        
                // Track conflict combinations based on conflict_checker outputs
        if (raw_conflicts != prev_raw_conflicts || 
            waw_conflicts != prev_waw_conflicts || 
            war_conflicts != prev_war_conflicts) begin
            
            // Get current conflict status
            has_raw = (raw_conflicts != prev_raw_conflicts);
            has_waw = (waw_conflicts != prev_waw_conflicts);
            has_war = (war_conflicts != prev_war_conflicts);
            
            // Update conflict combination counters
            case ({has_raw, has_waw, has_war})
                3'b100: raw_only_conflicts <= raw_only_conflicts + 1;  // RAW only
                3'b010: waw_only_conflicts <= waw_only_conflicts + 1;  // WAW only
                3'b001: war_only_conflicts <= war_only_conflicts + 1;  // WAR only
                3'b110: raw_waw_conflicts <= raw_waw_conflicts + 1;   // RAW + WAW
                3'b101: raw_war_conflicts <= raw_war_conflicts + 1;   // RAW + WAR
                3'b011: waw_war_conflicts <= waw_war_conflicts + 1;   // WAW + WAR
                3'b111: raw_waw_war_conflicts <= raw_waw_war_conflicts + 1; // All three
            endcase
            
            // Update previous values
            prev_raw_conflicts <= raw_conflicts;
            prev_waw_conflicts <= waw_conflicts;
            prev_war_conflicts <= war_conflicts;
        end
        
        // Track batch statistics
        if (m_axis_tvalid && m_axis_tready) begin
            // Record completion time for each transaction
            transaction_complete_time[total_transactions_batched] <= $time;
            // Only count unique transactions that complete
            if (total_transactions_batched < total_transactions_submitted) begin
                total_transactions_batched <= total_transactions_batched + 1;
                current_batch_size <= current_batch_size + 1;
                if (DEBUG_ENABLE)
                    $display("Time %0t: Transaction completed (total batched: %0d)", $time, total_transactions_batched);
            end
        end
        
        // Update batch statistics when batch completes
        if (batch_completed) begin
            total_batches <= total_batches + 1;
            if (DEBUG_ENABLE)
                $display("Time %0t: Batch %0d completed with %0d transactions (total batched: %0d)", 
                    $time, total_batches + 1, current_batch_size, total_transactions_batched);
            // Reset current batch counters
            current_batch_size <= 0;
        end
            
        // Handle batch completion
        if (batch_completed) begin
            total_batches <= total_batches + 1;
            batch_complete_time <= $time;
            
            // Update batch size statistics
            if (current_batch_size > max_batch_size_seen)
                max_batch_size_seen <= current_batch_size;
            if (current_batch_size < min_batch_size_seen && current_batch_size > 0)
                min_batch_size_seen <= current_batch_size;
                
            // Reset for next batch
            current_batch_size <= 0;
            batch_start_time <= $time;
            
            // Debug output for batch completion
            if (DEBUG_ENABLE) begin
                $display("\nBatch completed:");
                $display("  Total RAW conflicts: %0d", raw_conflicts);
                $display("  Total WAW conflicts: %0d", waw_conflicts);
                $display("  Total WAR conflicts: %0d", war_conflicts);
                $display("  Unique conflicting transactions: %0d", filter_hits);
                $display("  Transactions in batch: %0d", current_batch_size);
            end
        end
    end
end

// DUT instantiation
top #(
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
    .raw_conflicts(raw_conflicts),
    .waw_conflicts(waw_conflicts),
    .war_conflicts(war_conflicts),
    .filter_hits(filter_hits),
    .queue_occupancy(queue_occupancy),
    .transactions_processed(transactions_processed),
    .transactions_batched(transactions_batched),
    .batch_completed(batch_completed)
);

// Clock generation and cycle counting
initial begin
    clk = 0;
    total_cycles = 0;
    forever begin
        #5 clk = ~clk;
        if (clk) total_cycles = total_cycles + 1;
    end
end

    // Test stimulus
initial begin
    // Initialize signals and test counters
    rst_n = 0;
    s_axis_tdata_owner_programID = 0;
    s_axis_tdata_read_dependencies = 0;
    test_case_counter = 0;
    pattern_type = 0;
    s_axis_tdata_write_dependencies = 0;
    s_axis_tvalid = 0;
    m_axis_tready = 1;
    
    // Reset sequence
    #100 rst_n = 1;
    
    // Wait after reset
    repeat(10) @(posedge clk);
    
    // Generate test patterns
    $display("Starting test pattern generation for %d test cases...", NUM_TEST_CASES);
    
    while (test_case_counter < NUM_TEST_CASES) begin
        // Select pattern type based on counter
        pattern_type = test_case_counter % PATTERN_TYPES;
        
        // Wait for ready signal before attempting submission
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        
        // Generate the pattern with valid=0 first
        s_axis_tvalid = 0;
        case (pattern_type)
            0: generate_sequential_pattern();      // Sequential access pattern
            1: generate_strided_pattern();        // Strided access pattern
            2: generate_random_pattern();         // Random access pattern
            3: generate_hotspot_pattern();        // Hotspot access pattern
            4: generate_producer_consumer();      // Producer-consumer pattern
            5: generate_butterfly_pattern();      // Butterfly access pattern
            6: generate_all_to_all_pattern();    // All-to-all communication pattern
            7: generate_edge_cases();            // Edge cases and corner cases
        endcase
        
        // Now assert valid and wait for handshake
        @(posedge clk);
        s_axis_tvalid = 1;
        
        // Wait for successful handshake
        while (!(s_axis_tvalid && s_axis_tready)) @(posedge clk);
        
        // Clear valid after handshake
        @(posedge clk);
        s_axis_tvalid = 0;
        
        // Add delay between transactions to allow pipeline to process
        // This helps prevent overwhelming the conflict checker and allows
        // the batch stage to potentially complete
        repeat(5) @(posedge clk);
        
        // Progress reporting every 100 transactions
        if (test_case_counter % 100 == 0) begin
            $display("\nProgress Update - %0d/%0d test cases (%.1f%%)", 
                     test_case_counter, NUM_TEST_CASES, 
                     test_case_counter * 100.0 / NUM_TEST_CASES);
            $display("Current Pattern: %s", 
                     pattern_type == 0 ? "Sequential" :
                     pattern_type == 1 ? "Strided" :
                     pattern_type == 2 ? "Random" :
                     pattern_type == 3 ? "Hotspot" :
                     pattern_type == 4 ? "Producer-Consumer" :
                     pattern_type == 5 ? "Butterfly" :
                     pattern_type == 6 ? "All-to-All" :
                     "Edge Cases");
            $display("Conflicts - RAW: %0d, WAW: %0d, WAR: %0d", 
                     raw_conflicts, waw_conflicts, war_conflicts);
            $display("Transactions - Submitted: %0d, Batched: %0d, Conflicts: %0d",
                     total_transactions_submitted, transactions_batched, filter_hits);
            
            // Add extra delay after progress report to allow pipeline to catch up
            repeat(10) @(posedge clk);
        end
        
        test_case_counter = test_case_counter + 1;
    end
    
    // Wait for all transactions to complete
    repeat(100) @(posedge clk);
    
    // Final progress report
    $display("\nFinal Progress Report:");
    $display("Total transactions submitted: %0d", total_transactions_submitted);
    $display("Total transactions batched:  %0d", total_transactions_batched);
    $display("Total conflicts detected:    %0d", total_transactions_conflicted);
    $display("Conflicts by type:");
    $display("  RAW: %0d", raw_conflicts);
    $display("  WAW: %0d", waw_conflicts);
    $display("  WAR: %0d", war_conflicts);
    
    // Wait for completion
    repeat(100) @(posedge clk);
    
    // Calculate performance metrics
    simulation_time_ns = $time / 1000.0;  // Convert to ns
    transactions_per_cycle = total_transactions_batched * 1.0 / total_cycles;
    transactions_per_second = (total_transactions_batched * 1_000_000_000) / simulation_time_ns;
    throughput_gbps = (total_transactions_batched * 64.0 * 1_000_000_000) / (simulation_time_ns * 1_000_000_000);
    
    // Calculate batch statistics
    if (total_batches > 0) begin
        avg_batch_size = total_transactions_batched * 1.0 / total_batches;
        avg_batch_formation_time = (batch_complete_time - batch_start_time) / 1000.0;  // Convert to ns
    end else begin
        avg_batch_size = 0;
        avg_batch_formation_time = 0;
    end
    
    // Calculate transaction latency statistics
    min_transaction_latency = 1_000_000_000;  // Initialize to large value
    max_transaction_latency = 0;
    avg_transaction_latency = 0;
    
    if (total_transactions_batched > 0) begin
        for (integer i = 0; i < total_transactions_batched; i = i + 1) begin
            real latency;
            latency = (transaction_complete_time[i] - transaction_submit_time[i]) / 1_000_000_000.0;  // Convert ps to ms
            avg_transaction_latency = avg_transaction_latency + latency;
            
            if (latency < min_transaction_latency && latency > 0)
                min_transaction_latency = latency;
            if (latency > max_transaction_latency)
                max_transaction_latency = latency;
        end
        
        avg_transaction_latency = avg_transaction_latency / total_transactions_batched;
    end else begin
        min_transaction_latency = 0;
        max_transaction_latency = 0;
    end
    
    // Display results
    $display("\nTest completed! Performance Summary:");
    $display("----------------------------------------");
    $display("Total Transactions Statistics:");
    $display("  Submitted:  %0d", total_transactions_submitted);
    $display("  Conflicted: %0d (%.2f%%)", total_transactions_conflicted,
             total_transactions_submitted > 0 ? (total_transactions_conflicted * 100.0 / total_transactions_submitted) : 0);
    $display("  Conflict Resolution:");
    $display("    Initially conflicted but later batched: %0d", 
             total_transactions_conflicted - (total_transactions_submitted - total_transactions_batched));
    $display("    Permanently rejected due to conflicts: %0d",
             total_transactions_submitted - total_transactions_batched);
    $display("  Successfully batched: %0d (%.2f%%)", total_transactions_batched,
             total_transactions_submitted > 0 ? (total_transactions_batched * 100.0 / total_transactions_submitted) : 0);
    $display("\nDetailed Conflict Analysis:");
    $display("  Total conflicts by type:");
    $display("    RAW (Read-After-Write):  %0d", raw_conflicts);
    $display("    WAW (Write-After-Write): %0d", waw_conflicts);
    $display("    WAR (Write-After-Read):  %0d", war_conflicts);
    $display("    Total individual conflicts: %0d", raw_conflicts + waw_conflicts + war_conflicts);
    
    $display("  Conflict combinations:");
    $display("    Single conflict type:");
    $display("      RAW only: %0d", raw_only_conflicts);
    $display("      WAW only: %0d", waw_only_conflicts);
    $display("      WAR only: %0d", war_only_conflicts);
    $display("    Two conflict types:");
    $display("      RAW + WAW: %0d", raw_waw_conflicts);
    $display("      RAW + WAR: %0d", raw_war_conflicts);
    $display("      WAW + WAR: %0d", waw_war_conflicts);
    $display("    All conflict types:");
    $display("      RAW + WAW + WAR: %0d", raw_waw_war_conflicts);
    
    $display("  Conflict statistics:");
    $display("    Unique conflicting transactions: %0d", filter_hits);
    $display("    Single conflict transactions:   %0d (%.1f%%)",
             raw_only_conflicts + waw_only_conflicts + war_only_conflicts,
             filter_hits > 0 ? ((raw_only_conflicts + waw_only_conflicts + war_only_conflicts) * 100.0 / filter_hits) : 0);
    $display("    Multiple conflict transactions: %0d (%.1f%%)",
             raw_waw_conflicts + raw_war_conflicts + waw_war_conflicts + raw_waw_war_conflicts,
             filter_hits > 0 ? ((raw_waw_conflicts + raw_war_conflicts + waw_war_conflicts + raw_waw_war_conflicts) * 100.0 / filter_hits) : 0);

    $display("\nQueue Statistics:");
    $display("  Queue occupancy:        %0d", queue_occupancy);
    $display("  Transactions processed: %0d", total_transactions_submitted);
    $display("  Transactions batched:   %0d", total_transactions_batched);
    $display("\nPerformance Metrics:");
    $display("  Total clock cycles:     %0d", total_cycles);
    $display("  Simulation time:        %.2f ns", simulation_time_ns);
    $display("  Transactions/cycle:     %.3f", transactions_per_cycle);
    $display("  Transactions/second:    %.2f M", transactions_per_second / 1_000_000);
    $display("  Throughput:             %.2f Gbps", throughput_gbps);
    
    $display("\nBatch Statistics:");
    $display("  Total batches:          %0d", total_batches);
    $display("  Average batch size:     %.2f", avg_batch_size);
    $display("  Min batch size:         %0d", min_batch_size_seen);
    $display("  Max batch size:         %0d", max_batch_size_seen);
    $display("  Avg formation time:     %.2f ns", avg_batch_formation_time);
    
    $display("\nLatency Statistics:");
    $display("  Average latency:        %.2f ms", avg_transaction_latency / 1_000_000);
    $display("  Min latency:            %.2f ms", min_transaction_latency / 1_000_000);
    $display("  Max latency:            %.2f ms", max_transaction_latency / 1_000_000);
    $display("----------------------------------------");
    
    $finish;
end

// Monitor transactions
initial begin
    forever begin
        @(posedge clk);
        if (m_axis_tvalid && m_axis_tready) begin
            $display("Time %0t: Transaction output - Owner: %h, Read deps: %h, Write deps: %h",
                     $time, m_axis_tdata_owner_programID,
                     m_axis_tdata_read_dependencies, m_axis_tdata_write_dependencies);
        end
    end
end

// Pattern generation tasks
// Pattern generation tasks
task generate_sequential_pattern;
    reg [MAX_DEPENDENCIES-1:0] read_mask, write_mask;
    begin
        // Sequential access pattern: Each transaction depends on previous ones
        read_mask = (1 << (test_case_counter % MAX_DEPENDENCIES));
        write_mask = (1 << ((test_case_counter + 1) % MAX_DEPENDENCIES));
        s_axis_tdata_read_dependencies = read_mask;
        s_axis_tdata_write_dependencies = write_mask;
        s_axis_tdata_owner_programID = test_case_counter;
    end
endtask

task generate_strided_pattern;
    reg [MAX_DEPENDENCIES-1:0] read_mask, write_mask;
    begin
        // Strided access pattern: Access memory locations with fixed stride
        read_mask = (3 << (2 * (test_case_counter % (MAX_DEPENDENCIES/2))));
        write_mask = (3 << (2 * ((test_case_counter + 1) % (MAX_DEPENDENCIES/2))));
        s_axis_tdata_read_dependencies = read_mask;
        s_axis_tdata_write_dependencies = write_mask;
        s_axis_tdata_owner_programID = test_case_counter;
    end
endtask

task generate_random_pattern;
    reg [MAX_DEPENDENCIES-1:0] read_mask, write_mask;
    integer seed;
    begin
        // Random access pattern: Randomly select dependencies
        seed = test_case_counter;
        read_mask = $random(seed) & ((1 << MAX_DEPENDENCIES) - 1);
        write_mask = $random(seed) & ((1 << MAX_DEPENDENCIES) - 1);
        s_axis_tdata_read_dependencies = read_mask;
        s_axis_tdata_write_dependencies = write_mask;
        s_axis_tdata_owner_programID = test_case_counter;
    end
endtask

task generate_hotspot_pattern;
    reg [MAX_DEPENDENCIES-1:0] read_mask, write_mask;
    integer hotspot_center;
    begin
        // Hotspot access pattern: Concentrate accesses around certain locations
        hotspot_center = (test_case_counter / 10) % (MAX_DEPENDENCIES - 4);
        read_mask = 15'b111 << hotspot_center;
        write_mask = 15'b111 << (hotspot_center + 1);
        s_axis_tdata_read_dependencies = read_mask;
        s_axis_tdata_write_dependencies = write_mask;
        s_axis_tdata_owner_programID = test_case_counter;
    end
endtask

task generate_producer_consumer;
    reg [MAX_DEPENDENCIES-1:0] read_mask, write_mask;
    begin
        // Producer-consumer pattern: Alternating read-write dependencies
        if (test_case_counter % 2 == 0) begin
            // Producer writes to even locations
            read_mask = 0;
            write_mask = 15'b010101 << (test_case_counter % 8);
        end else begin
            // Consumer reads from odd locations
            read_mask = 15'b101010 << ((test_case_counter-1) % 8);
            write_mask = 0;
        end
        s_axis_tdata_read_dependencies = read_mask;
        s_axis_tdata_write_dependencies = write_mask;
        s_axis_tdata_owner_programID = test_case_counter;
    end
endtask

task generate_butterfly_pattern;
    reg [MAX_DEPENDENCIES-1:0] read_mask, write_mask;
    integer stage, offset;
    begin
        // Butterfly pattern: Pairs of locations interact
        stage = (test_case_counter / 2) % 4;
        offset = 1 << stage;
        if (test_case_counter % 2 == 0) begin
            read_mask = (1 << (test_case_counter % MAX_DEPENDENCIES));
            write_mask = (1 << ((test_case_counter + offset) % MAX_DEPENDENCIES));
        end else begin
            read_mask = (1 << ((test_case_counter - offset) % MAX_DEPENDENCIES));
            write_mask = (1 << (test_case_counter % MAX_DEPENDENCIES));
        end
        s_axis_tdata_read_dependencies = read_mask;
        s_axis_tdata_write_dependencies = write_mask;
        s_axis_tdata_owner_programID = test_case_counter;
    end
endtask

task generate_all_to_all_pattern;
    reg [MAX_DEPENDENCIES-1:0] read_mask, write_mask;
    begin
        // All-to-all pattern: Each transaction touches multiple locations
        read_mask = (15'b11111 << (test_case_counter % (MAX_DEPENDENCIES-4)));
        write_mask = (15'b11111 << ((test_case_counter + 2) % (MAX_DEPENDENCIES-4)));
        s_axis_tdata_read_dependencies = read_mask;
        s_axis_tdata_write_dependencies = write_mask;
        s_axis_tdata_owner_programID = test_case_counter;
    end
endtask

task generate_edge_cases;
    reg [MAX_DEPENDENCIES-1:0] read_mask, write_mask;
    reg [2:0] case_type;
    begin
        // Edge cases: Various corner cases and boundary conditions
        case_type = test_case_counter % 8;
        case (case_type)
            0: begin // All zeros
                read_mask = 0;
                write_mask = 0;
            end
            1: begin // All ones
                read_mask = {MAX_DEPENDENCIES{1'b1}};
                write_mask = {MAX_DEPENDENCIES{1'b1}};
            end
            2: begin // Alternating bits
                read_mask = {MAX_DEPENDENCIES{2'b10}};
                write_mask = {MAX_DEPENDENCIES{2'b01}};
            end
            3: begin // Single bit set
                read_mask = 1 << (test_case_counter % MAX_DEPENDENCIES);
                write_mask = 1 << ((test_case_counter + 1) % MAX_DEPENDENCIES);
            end
            4: begin // Walking ones
                read_mask = 1 << (test_case_counter % MAX_DEPENDENCIES);
                write_mask = 1 << ((test_case_counter + 1) % MAX_DEPENDENCIES);
            end
            5: begin // Walking zeros
                read_mask = ~(1 << (test_case_counter % MAX_DEPENDENCIES));
                write_mask = ~(1 << ((test_case_counter + 1) % MAX_DEPENDENCIES));
            end
            6: begin // Sparse pattern
                read_mask = 1 << (test_case_counter % 4) | 1 << ((test_case_counter + 4) % 8);
                write_mask = 1 << ((test_case_counter + 1) % 4) | 1 << ((test_case_counter + 5) % 8);
            end
            7: begin // Dense pattern
                read_mask = ~(1 << (test_case_counter % 4) | 1 << ((test_case_counter + 4) % 8));
                write_mask = ~(1 << ((test_case_counter + 1) % 4) | 1 << ((test_case_counter + 5) % 8));
            end
        endcase
        s_axis_tdata_read_dependencies = read_mask;
        s_axis_tdata_write_dependencies = write_mask;
        s_axis_tdata_owner_programID = test_case_counter;
    end
endtask

endmodule