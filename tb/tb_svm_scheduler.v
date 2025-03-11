`timescale 1ns / 1ps

module tb_svm_scheduler;

// Parameters
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

// Monitor transaction submission and completion
always @(posedge clk) begin
    if (!rst_n) begin
        total_transactions_submitted <= 0;
        total_transactions_conflicted <= 0;
        total_transactions_batched <= 0;
    end else begin
        // Count submitted transactions
        if (s_axis_tvalid && s_axis_tready)
            total_transactions_submitted <= total_transactions_submitted + 1;
            
        // Count unique conflicted transactions (avoid double-counting multi-conflict transactions)
        total_transactions_conflicted <= filter_hits;  // filter_hits tracks unique conflicted transactions
            
        // Count batched transactions
        if (transactions_batched > total_transactions_batched)
            total_transactions_batched <= transactions_batched;
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
    .transactions_batched(transactions_batched)
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
    
    // Test Case 6: Full batch
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
    $display("  RAW conflicts: %0d", raw_conflicts);
    $display("  WAW conflicts: %0d", waw_conflicts);
    $display("  WAR conflicts: %0d", war_conflicts);
    $display("  Unique transaction conflicts: %0d", filter_hits);
    $display("\nQueue Statistics:");
    $display("  Queue occupancy:        %0d", queue_occupancy);
    $display("  Transactions processed: %0d", transactions_processed);
    $display("  Transactions batched:   %0d", transactions_batched);
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