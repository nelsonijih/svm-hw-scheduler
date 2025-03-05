///////////////
// test bench - instantiate the top system, and drive test signals/data to design.
//////////////

`timescale 1ns/1ps

module tb_svm_scheduler;

    // Parameters
    parameter MAX_DEPENDENCIES = 1024;
    parameter MAX_BATCH_SIZE = 8;
    parameter BATCH_TIMEOUT_CYCLES = 100;
    parameter MAX_PENDING_TRANSACTIONS = 16;
    parameter INSERTION_QUEUE_DEPTH = 8;
    parameter SIM_TIMEOUT = 10000; // Simulation timeout in clock cycles
    
    // Clock and reset
    reg clk;
    reg rst_n;
    
    // AXI-Stream input interface
    reg s_axis_tvalid;
    wire s_axis_tready;
    reg [63:0] s_axis_tdata_owner_programID;
    reg [1023:0] s_axis_tdata_read_dependencies;
    reg [1023:0] s_axis_tdata_write_dependencies;
    
    // AXI-Stream output interface
    wire m_axis_tvalid;
    reg m_axis_tready;
    wire [63:0] m_axis_tdata_owner_programID;
    wire [1023:0] m_axis_tdata_read_dependencies;
    wire [1023:0] m_axis_tdata_write_dependencies;
    
    // Performance monitoring
    wire [31:0] raw_conflicts;
    wire [31:0] waw_conflicts;
    wire [31:0] war_conflicts;
    wire [31:0] filter_hits;
    wire [31:0] queue_occupancy;
    wire [31:0] transactions_processed;
    
    // Simulation timeout counter
    reg [31:0] timeout_counter;
    
    // Instantiate the top module
    top #(
        .MAX_DEPENDENCIES(MAX_DEPENDENCIES),
        .MAX_BATCH_SIZE(MAX_BATCH_SIZE),
        .BATCH_TIMEOUT_CYCLES(BATCH_TIMEOUT_CYCLES),
        .MAX_PENDING_TRANSACTIONS(MAX_PENDING_TRANSACTIONS),
        .INSERTION_QUEUE_DEPTH(INSERTION_QUEUE_DEPTH)
    ) svm_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata_owner_programID(s_axis_tdata_owner_programID),
        .s_axis_tdata_read_dependencies(s_axis_tdata_read_dependencies),
        .s_axis_tdata_write_dependencies(s_axis_tdata_write_dependencies),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata_owner_programID(m_axis_tdata_owner_programID),
        .m_axis_tdata_read_dependencies(m_axis_tdata_read_dependencies),
        .m_axis_tdata_write_dependencies(m_axis_tdata_write_dependencies),
        .raw_conflicts(raw_conflicts),
        .waw_conflicts(waw_conflicts),
        .war_conflicts(war_conflicts),
        .filter_hits(filter_hits),
        .queue_occupancy(queue_occupancy),
        .transactions_processed(transactions_processed)
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(10/2) clk = ~clk;
    end
    
    // Simulation timeout
    always @(posedge clk) begin
        if (timeout_counter >= SIM_TIMEOUT) begin
            $display("Simulation timeout reached at %0t", $time);
            $display("Debug info:");
            $display("  s_axis_tvalid = %b, s_axis_tready = %b", s_axis_tvalid, s_axis_tready);
            $display("  m_axis_tvalid = %b, m_axis_tready = %b", m_axis_tvalid, m_axis_tready);
            $display("  raw_conflicts = %0d", raw_conflicts);
            $display("  waw_conflicts = %0d", waw_conflicts);
            $display("  war_conflicts = %0d", war_conflicts);
            $display("  filter_hits = %0d", filter_hits);
            $display("  queue_occupancy = %0d", queue_occupancy);
            $display("  transactions_processed = %0d", transactions_processed);
            $finish;
        end else begin
            timeout_counter <= timeout_counter + 1;
        end
    end
    
    // Task to submit a transaction
    task submit_transaction;
        input [63:0] owner_programID;
        input [1023:0] read_dependencies;
        input [1023:0] write_dependencies;
        begin
            // Wait for ready
            wait(s_axis_tready);
            
            // Submit transaction
            @(posedge clk);
            s_axis_tvalid = 1;
            s_axis_tdata_owner_programID = owner_programID;
            s_axis_tdata_read_dependencies = read_dependencies;
            s_axis_tdata_write_dependencies = write_dependencies;
            
            // Wait for handshake
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            
            // Deassert valid
            s_axis_tvalid = 0;
        end
    endtask
    
    // Test stimulus
    initial begin
        // Initialize signals
        s_axis_tvalid = 0;
        s_axis_tdata_owner_programID = 0;
        s_axis_tdata_read_dependencies = 0;
        s_axis_tdata_write_dependencies = 0;
        m_axis_tready = 1;
        timeout_counter = 0;
        
        // Set up VCD dumping
        $dumpfile("build/waves.vcd");
        $dumpvars(0, tb_svm_scheduler);
        
        // Reset
        rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        
        // Wait for stabilization
        repeat(10) @(posedge clk);
        
        // Test Case 1: Non-conflicting transactions
        $display("\nTest Case 1: Non-conflicting transactions");
        $display("Submitting 3 transactions with unique dependencies");
        
        // Transaction 1: Read from region 0, write to region 1
        $display("Submitting transaction 1 at time %0t", $time);
        submit_transaction(
            64'h1,
            1024'h1,  // Read from region 0
            1024'h2   // Write to region 1
        );
        repeat(10) @(posedge clk);
        
        // Transaction 2: Read from region 2, write to region 3
        $display("Submitting transaction 2 at time %0t", $time);
        submit_transaction(
            64'h2,
            1024'h4,  // Read from region 2
            1024'h8   // Write to region 3
        );
        repeat(10) @(posedge clk);
        
        // Transaction 3: Read from region 4, write to region 5
        $display("Submitting transaction 3 at time %0t", $time);
        submit_transaction(
            64'h3,
            1024'h10,  // Read from region 4
            1024'h20   // Write to region 5
        );
        repeat(10) @(posedge clk);
        
        // Test Case 2: RAW (Read-After-Write) conflicts
        $display("\nTest Case 2: RAW (Read-After-Write) conflicts");
        $display("Submitting 3 transactions with RAW conflicts");
        
        // Transaction 4: Write to region 6
        submit_transaction(
            64'h4,
            1024'h0,     // No reads
            1024'h40     // Write to region 6
        );
        repeat(10) @(posedge clk);
        
        // Transaction 5: Read from region 6 (RAW conflict)
        submit_transaction(
            64'h5,
            1024'h40,    // Read from region 6
            1024'h0      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Transaction 6: Read from region 6 (RAW conflict)
        submit_transaction(
            64'h6,
            1024'h40,    // Read from region 6
            1024'h0      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Test Case 3: Mixed conflicting and non-conflicting transactions
        $display("\nTest Case 3: Mixed conflicting and non-conflicting transactions");
        $display("Submitting 4 transactions alternating between conflict and no conflict");
        
        // Transaction 7: Write to region 7
        submit_transaction(
            64'h7,
            1024'h0,     // No reads
            1024'h80     // Write to region 7
        );
        repeat(10) @(posedge clk);
        
        // Transaction 8: Read from region 8 (no conflict)
        submit_transaction(
            64'h8,
            1024'h100,   // Read from region 8
            1024'h0      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Transaction 9: Read from region 7 (RAW conflict)
        submit_transaction(
            64'h9,
            1024'h80,    // Read from region 7
            1024'h0      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Transaction 10: Write to region 9 (no conflict)
        submit_transaction(
            64'h10,
            1024'h0,     // No reads
            1024'h200    // Write to region 9
        );
        repeat(10) @(posedge clk);
        
        // Test Case 4: WAW (Write-After-Write) conflicts
        $display("\nTest Case 4: WAW (Write-After-Write) conflicts");
        $display("Submitting transactions with WAW conflicts");
        
        // Transaction 11: Write to region 10
        submit_transaction(
            64'h11,
            1024'h0,     // No reads
            1024'h400    // Write to region 10
        );
        repeat(10) @(posedge clk);
        
        // Transaction 12: Write to region 10 (WAW conflict)
        submit_transaction(
            64'h12,
            1024'h0,     // No reads
            1024'h400    // Write to region 10 (conflicts with Transaction 11)
        );
        repeat(10) @(posedge clk);
        
        // Transaction 13: Write to region 11 (no conflict)
        submit_transaction(
            64'h13,
            1024'h0,     // No reads
            1024'h800    // Write to region 11
        );
        repeat(10) @(posedge clk);
        
        // Test Case 5: WAR (Write-After-Read) conflicts
        $display("\nTest Case 5: WAR (Write-After-Read) conflicts");
        $display("Submitting transactions with WAR conflicts");
        
        // Transaction 14: Read from region 12
        submit_transaction(
            64'h14,
            1024'h1000,  // Read from region 12
            1024'h0      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Transaction 15: Write to region 12 (WAR conflict)
        submit_transaction(
            64'h15,
            1024'h0,     // No reads
            1024'h1000   // Write to region 12 (conflicts with Transaction 14 read)
        );
        repeat(10) @(posedge clk);
        
        // Test Case 6: Multiple conflict types
        $display("\nTest Case 6: Multiple conflict types");
        $display("Submitting transactions with multiple conflict types");
        
        // Transaction 16: Read from region 13, Write to region 14
        submit_transaction(
            64'h16,
            1024'h2000,  // Read from region 13
            1024'h4000   // Write to region 14
        );
        repeat(10) @(posedge clk);
        
        // Transaction 17: Read from region 14, Write to region 13
        // This creates both RAW (reads region 14 which Transaction 16 wrote to)
        // and WAR (writes to region 13 which Transaction 16 read from)
        submit_transaction(
            64'h17,
            1024'h4000,  // Read from region 14 (RAW conflict with Transaction 16)
            1024'h2000   // Write to region 13 (WAR conflict with Transaction 16)
        );
        repeat(10) @(posedge clk);
        
        // Wait for processing
        repeat(100) @(posedge clk);
        
        // Display test results
        $display("\nTest Results:");
        $display("Raw Conflicts: %0d", raw_conflicts);
        $display("WAW Conflicts: %0d", waw_conflicts);
        $display("WAR Conflicts: %0d", war_conflicts);
        $display("Total Conflicts: %0d", raw_conflicts + waw_conflicts + war_conflicts);
        $display("Rejected Transactions: %0d", filter_hits);
        $display("Queue Occupancy: %0d", queue_occupancy);
        $display("Transactions Processed: %0d", transactions_processed);
        
        // End simulation
        #100 $finish;
    end

endmodule
