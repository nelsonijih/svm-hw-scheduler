module tb_simplified;

    // Parameters
    parameter MAX_DEPENDENCIES = 1024;
    parameter MAX_BATCH_SIZE = 8;
    parameter BATCH_TIMEOUT_CYCLES = 100;
    parameter MAX_PENDING_TRANSACTIONS = 16;
    parameter INSERTION_QUEUE_DEPTH = 8;
    
    // Testbench signals
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
    
    // Instantiate the DUT
    top #(
        .MAX_DEPENDENCIES(MAX_DEPENDENCIES),
        .MAX_BATCH_SIZE(MAX_BATCH_SIZE),
        .BATCH_TIMEOUT_CYCLES(BATCH_TIMEOUT_CYCLES),
        .MAX_PENDING_TRANSACTIONS(MAX_PENDING_TRANSACTIONS),
        .INSERTION_QUEUE_DEPTH(INSERTION_QUEUE_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        
        // AXI-Stream input interface
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata_owner_programID(s_axis_tdata_owner_programID),
        .s_axis_tdata_read_dependencies(s_axis_tdata_read_dependencies),
        .s_axis_tdata_write_dependencies(s_axis_tdata_write_dependencies),
        
        // AXI-Stream output interface
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
        .transactions_processed(transactions_processed)
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    // Test vectors
    reg [63:0] test_owner_ids [0:9];
    reg [1023:0] test_read_deps [0:9];
    reg [1023:0] test_write_deps [0:9];
    
    // Initialize test vectors
    initial begin
        // Transaction 0: No conflicts
        test_owner_ids[0] = 64'h0000_0000_0000_0001;
        test_read_deps[0] = {1023'b0, 1'b1};   // Bit 0 set for read
        test_write_deps[0] = {1022'b0, 1'b1, 1'b0}; // Bit 1 set for write
        
        // Transaction 1: No conflicts with Transaction 0
        test_owner_ids[1] = 64'h0000_0000_0000_0002;
        test_read_deps[1] = {1021'b0, 1'b1, 2'b0};  // Bit 2 set for read
        test_write_deps[1] = {1020'b0, 1'b1, 3'b0}; // Bit 3 set for write
        
        // Transaction 2: RAW conflict with Transaction 0 (reads bit 1 which Transaction 0 wrote)
        test_owner_ids[2] = 64'h0000_0000_0000_0003;
        test_read_deps[2] = {1022'b0, 1'b1, 1'b0};  // Bit 1 set for read (conflicts with Transaction 0 write)
        test_write_deps[2] = {1019'b0, 1'b1, 4'b0}; // Bit 4 set for write
        
        // Transaction 3: WAW conflict with Transaction 1 (writes bit 3 which Transaction 1 wrote)
        test_owner_ids[3] = 64'h0000_0000_0000_0004;
        test_read_deps[3] = {1018'b0, 1'b1, 5'b0};  // Bit 5 set for read
        test_write_deps[3] = {1020'b0, 1'b1, 3'b0}; // Bit 3 set for write (conflicts with Transaction 1 write)
        
        // Transaction 4: WAR conflict with Transaction 1 (writes bit 2 which Transaction 1 read)
        test_owner_ids[4] = 64'h0000_0000_0000_0005;
        test_read_deps[4] = {1017'b0, 1'b1, 6'b0};  // Bit 6 set for read
        test_write_deps[4] = {1021'b0, 1'b1, 2'b0}; // Bit 2 set for write (conflicts with Transaction 1 read)
        
        // Transaction 5: Multiple conflicts (RAW with Transaction 0, WAW with Transaction 1)
        test_owner_ids[5] = 64'h0000_0000_0000_0006;
        test_read_deps[5] = {1022'b0, 1'b1, 1'b0};  // Bit 1 set for read (RAW with Transaction 0)
        test_write_deps[5] = {1020'b0, 1'b1, 3'b0}; // Bit 3 set for write (WAW with Transaction 1)
        
        // Transaction 6: No conflicts (new bits)
        test_owner_ids[6] = 64'h0000_0000_0000_0007;
        test_read_deps[6] = {1016'b0, 1'b1, 7'b0};  // Bit 7 set for read
        test_write_deps[6] = {1015'b0, 1'b1, 8'b0}; // Bit 8 set for write
        
        // Transaction 7: RAW conflict with Transaction 6
        test_owner_ids[7] = 64'h0000_0000_0000_0008;
        test_read_deps[7] = {1015'b0, 1'b1, 8'b0};  // Bit 8 set for read (conflicts with Transaction 6 write)
        test_write_deps[7] = {1014'b0, 1'b1, 9'b0}; // Bit 9 set for write
        
        // Transaction 8: WAW conflict with Transaction 7
        test_owner_ids[8] = 64'h0000_0000_0000_0009;
        test_read_deps[8] = {1013'b0, 1'b1, 10'b0}; // Bit 10 set for read
        test_write_deps[8] = {1014'b0, 1'b1, 9'b0}; // Bit 9 set for write (conflicts with Transaction 7 write)
        
        // Transaction 9: No conflicts (new bits)
        test_owner_ids[9] = 64'h0000_0000_0000_000A;
        test_read_deps[9] = {1012'b0, 1'b1, 11'b0}; // Bit 11 set for read
        test_write_deps[9] = {1011'b0, 1'b1, 12'b0}; // Bit 12 set for write
    end
    
    // Test procedure
    integer i;
    integer wait_cycles;
    integer accepted_count;
    integer rejected_count;
    
    initial begin
        // Dump waveforms
        $dumpfile("simplified.vcd");
        $dumpvars(0, tb_simplified);
        
        // Initialize signals
        rst_n = 0;
        s_axis_tvalid = 0;
        s_axis_tdata_owner_programID = 0;
        s_axis_tdata_read_dependencies = 0;
        s_axis_tdata_write_dependencies = 0;
        m_axis_tready = 1;
        
        // Reset for a few cycles
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        
        // Initialize counters
        accepted_count = 0;
        rejected_count = 0;
        
        // Submit transactions
        for (i = 0; i < 10; i = i + 1) begin
            // Wait for ready
            wait_cycles = 0;
            while (!s_axis_tready && wait_cycles < 100) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            
            if (wait_cycles >= 100) begin
                $display("Error: Timeout waiting for s_axis_tready");
                $finish;
            end
            
            // Submit transaction
            s_axis_tvalid = 1;
            s_axis_tdata_owner_programID = test_owner_ids[i];
            s_axis_tdata_read_dependencies = test_read_deps[i];
            s_axis_tdata_write_dependencies = test_write_deps[i];
            
            $display("Submitting transaction %d at time %0t", i, $time);
            $display("  Owner ID: %h", test_owner_ids[i]);
            $display("  Read dependencies: %h", test_read_deps[i]);
            $display("  Write dependencies: %h", test_write_deps[i]);
            
            @(posedge clk);
            s_axis_tvalid = 0;
            
            // Wait a few cycles between transactions
            repeat (5) @(posedge clk);
        end
        
        // Wait for all transactions to be processed
        repeat (200) @(posedge clk);
        
        // Display results
        $display("\nTest Results:");
        $display("  RAW Conflicts: %d", raw_conflicts);
        $display("  WAW Conflicts: %d", waw_conflicts);
        $display("  WAR Conflicts: %d", war_conflicts);
        $display("  Total Conflicts: %d", raw_conflicts + waw_conflicts + war_conflicts);
        $display("  Rejected Transactions: %d", filter_hits);
        $display("  Processed Transactions: %d", transactions_processed);
        
        $finish;
    end
    
    // Monitor output transactions
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            accepted_count = accepted_count + 1;
            $display("Transaction accepted at time %0t", $time);
            $display("  Owner ID: %h", m_axis_tdata_owner_programID);
            $display("  Read dependencies: %h", m_axis_tdata_read_dependencies);
            $display("  Write dependencies: %h", m_axis_tdata_write_dependencies);
        end
    end

endmodule
