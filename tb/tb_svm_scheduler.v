`timescale 1ns / 1ps

module tb_svm_scheduler;

// Parameters
parameter DEBUG_ENABLE = 1;  // Enable debug output

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
            total_transactions_batched <= total_transactions_batched + 1;
            current_batch_size <= current_batch_size + 1;
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
    // Initialize signals
    rst_n = 0;
    s_axis_tdata_owner_programID = 0;
    s_axis_tdata_read_dependencies = 0;
    s_axis_tdata_write_dependencies = 0;
    s_axis_tvalid = 0;
    m_axis_tready = 1;
    
    // Reset sequence
    #100 rst_n = 1;
    
    // Test Case 1: No conflicts
    // T1: Read bit 0, Write bit 1
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h1;
    s_axis_tdata_read_dependencies = 1'b1;
    s_axis_tdata_write_dependencies = 2'b10;
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    
    // Test Case 2: RAW Conflict (handled directly by conflict_checker)
    // T2: Read bit 1 (conflicts with T1's write)
    #20;
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h2;
    s_axis_tdata_read_dependencies = 2'b10;
    s_axis_tdata_write_dependencies = 0;
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    
    // Test Case 3: WAW Conflict (handled directly by conflict_checker)
    // T3: Write bit 1 (conflicts with T1's write)
    #20;
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h3;
    s_axis_tdata_read_dependencies = 0;
    s_axis_tdata_write_dependencies = 2'b10;
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    
    // Test Case 4: WAR Conflict (handled directly by conflict_checker)
    // T4: Write bit 0 (conflicts with T1's read)
    #20;
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h4;
    s_axis_tdata_read_dependencies = 0;
    s_axis_tdata_write_dependencies = 1'b1;
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    
    // Test Case 5: Batch timeout
    // Wait for BATCH_TIMEOUT_CYCLES
    repeat(BATCH_TIMEOUT_CYCLES + 10) @(posedge clk);
    
    // Test Case 6: Full batch with no conflicts
    // Send MAX_BATCH_SIZE transactions without conflicts
    repeat(MAX_BATCH_SIZE) begin
        @(posedge clk);
        s_axis_tdata_owner_programID = 64'h5;
        s_axis_tdata_read_dependencies = {MAX_DEPENDENCIES{1'b0}};
        s_axis_tdata_write_dependencies = {MAX_DEPENDENCIES{1'b0}};
        s_axis_tdata_read_dependencies[MAX_DEPENDENCIES-1] = 1'b1;
        s_axis_tvalid = 1;
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        s_axis_tvalid = 0;
    end
    
    // Test Case 7: Stress test with mixed conflicts
    // Send rapid transactions with various dependency patterns
    repeat(8) begin
        @(posedge clk);
        s_axis_tdata_owner_programID = 64'h6;
        // Create overlapping read/write regions
        s_axis_tdata_read_dependencies = {MAX_DEPENDENCIES{1'b0}};
        s_axis_tdata_write_dependencies = {MAX_DEPENDENCIES{1'b0}};
        s_axis_tdata_read_dependencies[3:0] = 4'b1111;  // Read first 4 bits
        s_axis_tdata_write_dependencies[7:4] = 4'b1111; // Write next 4 bits
        s_axis_tvalid = 1;
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        s_axis_tvalid = 0;
    end
    
    // Test Case 8: Back-to-back transactions
    // Test scheduler's ability to handle consecutive transactions
    repeat(4) begin
        @(posedge clk);
        s_axis_tdata_owner_programID = 64'h7;
        // Alternate between read-heavy and write-heavy patterns
        s_axis_tdata_read_dependencies = {MAX_DEPENDENCIES{1'b0}};
        s_axis_tdata_write_dependencies = {MAX_DEPENDENCIES{1'b0}};
        s_axis_tdata_read_dependencies[15:0] = 16'hFFFF;  // Read first 16 bits
        s_axis_tvalid = 1;
        @(posedge clk);
        s_axis_tdata_read_dependencies = {MAX_DEPENDENCIES{1'b0}};
        s_axis_tdata_write_dependencies[15:0] = 16'hFFFF;  // Write first 16 bits
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk);
        s_axis_tvalid = 0;
    end
    
    // Test Case 2: RAW Conflict
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h2;
    s_axis_tdata_read_dependencies = 2'b10;   // Read from T1's write location
    s_axis_tdata_write_dependencies = 0;
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    #20;  // Wait for conflict detection
    
    // Test Case 3: WAW Conflict
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h3;
    s_axis_tdata_read_dependencies = 0;
    s_axis_tdata_write_dependencies = 2'b10;  // Write to T1's write location
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    #20;  // Wait for conflict detection
    
    // Test Case 4: WAR Conflict
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h4;
    s_axis_tdata_read_dependencies = 0;
    s_axis_tdata_write_dependencies = 2'b01;  // Write to T1's read location
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    #20;  // Wait for conflict detection
    
    // Test Case 7: Multiple conflicts in single transaction
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h7;
    s_axis_tdata_read_dependencies = 2'b10;   // Read from T1's write location (RAW)
    s_axis_tdata_write_dependencies = 2'b11;  // Write to both T1's read and write locations (WAW+WAR)
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    #20;  // Wait for conflict detection
    
    // Test Case 8: Another WAW conflict
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h8;
    s_axis_tdata_read_dependencies = 0;
    s_axis_tdata_write_dependencies = 2'b10;  // Write to T1's write location (WAW)
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    #20;  // Wait for conflict detection
    
    // Test Case 9: Another RAW conflict
    @(posedge clk);
    s_axis_tdata_owner_programID = 64'h9;
    s_axis_tdata_read_dependencies = 2'b10;  // Read from T1's write location (RAW)
    s_axis_tdata_write_dependencies = 0;
    s_axis_tvalid = 1;
    @(posedge clk);
    while (!s_axis_tready) @(posedge clk);
    s_axis_tvalid = 0;
    
    // Test Case 8: Back pressure
    m_axis_tready = 0;
    repeat(10) @(posedge clk);
    m_axis_tready = 1;
    
    // Wait for completion
    #1000;
    
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
            latency = (transaction_complete_time[i] - transaction_submit_time[i]) / 1000.0;  // Convert to ns
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
    $display("  Batched:    %0d (%.2f%%)", total_transactions_batched,
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
    $display("  Transactions processed: %0d", transactions_processed);
    $display("  Transactions batched:   %0d", transactions_batched);
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
    $display("  Average latency:        %.2f ns", avg_transaction_latency);
    $display("  Min latency:            %.2f ns", min_transaction_latency);
    $display("  Max latency:            %.2f ns", max_transaction_latency);
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

endmodule