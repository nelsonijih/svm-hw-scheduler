///////////////
// test bench - instantiate the top system, and drive test signals/data to design.
//////////////

`timescale 1ns/1ps

module tb_svm_scheduler;

    // Parameters
    parameter MAX_DEPENDENCIES = 256;
    parameter MAX_BATCH_SIZE = 8;  // Match top.v parameter
    parameter BATCH_TIMEOUT_CYCLES = 100;
    parameter MAX_PENDING_TRANSACTIONS = 16;
    parameter INSERTION_QUEUE_DEPTH = 8;
    parameter SIM_TIMEOUT = 10000; // Simulation timeout in clock cycles
    parameter DEBUG_ENABLE = 1;    // Enable debug output
    
    // Clock and reset
    reg clk;
    reg rst_n;
    
    // AXI-Stream input interface
    reg s_axis_tvalid;
    wire s_axis_tready;
    reg [63:0] s_axis_tdata_owner_programID;
    reg [MAX_DEPENDENCIES-1:0] s_axis_tdata_read_dependencies;
    reg [MAX_DEPENDENCIES-1:0] s_axis_tdata_write_dependencies;
    
    // AXI-Stream output interface
    wire m_axis_tvalid;
    reg m_axis_tready;
    wire [63:0] m_axis_tdata_owner_programID;
    wire [MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies;
    wire [MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies;
    
    // Performance monitoring
    wire [31:0] raw_conflicts;
    wire [31:0] waw_conflicts;
    wire [31:0] war_conflicts;
    wire [31:0] filter_hits;
    wire [31:0] queue_occupancy;
    wire [31:0] transactions_processed;
    
    // Performance monitoring
    reg [31:0] total_transactions;      // Total transactions submitted to system
    reg [31:0] total_batched_transactions; // Total transactions included in batches
    reg [31:0] prev_transactions;
    reg [31:0] total_batches;
    reg [31:0] empty_batches;
    reg [31:0] max_batch_transactions;
    reg [31:0] current_batch_transactions;
    reg [31:0] full_batches;           // Batches with MAX_BATCH_SIZE transactions
    reg [31:0] batch_start_time;       // Start time of current batch
    reg [31:0] total_batch_time;       // Total time spent in batches
    reg [31:0] min_batch_time;         // Minimum time spent in a batch
    reg [31:0] max_batch_time;         // Maximum time spent in a batch
    reg [31:0] batch_time;             // Time taken by current batch
    
    // Simulation timeout counter
    reg [31:0] timeout_counter;
    
    // Monitor batch completions and timing
    always @(posedge clk) begin
        if (!rst_n) begin
            total_batches <= 32'd0;
            empty_batches <= 32'd0;
            max_batch_transactions <= 32'd0;
            current_batch_transactions <= 32'd0;
            full_batches <= 32'd0;
            total_batched_transactions <= 32'd0;
            batch_start_time <= $time;
            total_batch_time <= 32'd0;
            min_batch_time <= 32'hFFFFFFFF;
            max_batch_time <= 32'd0;
            prev_transactions <= 32'd0;
        end else begin
            // Track current batch transactions
            if (svm_scheduler.batch_inst.transaction_accepted) begin
                // Get the actual batch count from the batch module
                current_batch_transactions <= svm_scheduler.batch_inst.batch_count;
                
                // Start timing on first transaction in batch
                if (svm_scheduler.batch_inst.batch_count == 0) begin
                    batch_start_time <= $time;
                end
                
                // Debug output
                $display("\nTransaction added to batch:");
                $display("  Current batch size: %0d", svm_scheduler.batch_inst.batch_count + 1);
                $display("  Max batch size: %0d", MAX_BATCH_SIZE);
                $display("  Transaction accepted: %0d", svm_scheduler.batch_inst.transaction_accepted);
            end
            
            // Keep track of processed transactions separately
            if (transactions_processed > prev_transactions) begin
                prev_transactions <= transactions_processed;
            end
            
            // Handle batch completion
            if (svm_scheduler.batch_completed) begin
                if (svm_scheduler.batch_inst.batch_count > 0) begin
                    total_batches <= total_batches + 32'd1;
                    // Use the actual batch count
                    total_batched_transactions <= total_batched_transactions + svm_scheduler.batch_inst.batch_count;
                    
                    // Update batch statistics
                    if (svm_scheduler.batch_inst.batch_count >= MAX_BATCH_SIZE) begin
                        full_batches <= full_batches + 32'd1;
                        max_batch_transactions <= MAX_BATCH_SIZE;
                    end else if (svm_scheduler.batch_inst.batch_count == 0) begin
                        empty_batches <= empty_batches + 32'd1;
                    end else if (svm_scheduler.batch_inst.batch_count > max_batch_transactions && svm_scheduler.batch_inst.batch_count < MAX_BATCH_SIZE) begin
                        max_batch_transactions <= svm_scheduler.batch_inst.batch_count;
                    end
                    
                    // Calculate batch time (in clock cycles)
                    batch_time = ($time - batch_start_time) / 20; // Convert to clock cycles (20ps per cycle)
                    total_batch_time <= total_batch_time + batch_time;
                    
                    // Update min/max batch times
                    if (batch_time < min_batch_time || min_batch_time == 32'hFFFFFFFF) begin
                        min_batch_time <= batch_time;
                    end
                    if (batch_time > max_batch_time) begin
                        max_batch_time <= batch_time;
                    end
                    
                    // Display detailed batch completion info
                    $display("\nBatch %0d completed:", total_batches + 32'd1);
                    $display("  Number of transactions: %0d", current_batch_transactions);
                    $display("  Time taken: %0d cycles", batch_time);
                    $display("  Running statistics:");
                    $display("    Total batches so far: %0d", total_batches + 1);
                    $display("    Total batched transactions: %0d", total_batched_transactions);
                    $display("    Max transactions in a batch: %0d", 
                             current_batch_transactions > max_batch_transactions ? current_batch_transactions : max_batch_transactions);
                    
                    // Reset current batch tracking
                    current_batch_transactions <= 32'd0;
                end
            end
        end
    end
    
    // Task to submit a transaction and update counters
    task submit_transaction;
        input [63:0] owner_programID;
        input [MAX_DEPENDENCIES-1:0] read_dependencies;
        input [MAX_DEPENDENCIES-1:0] write_dependencies;
        begin
            $display("Submitting transaction %0h at time %0d", owner_programID, $time);
            total_transactions = total_transactions + 1;
            s_axis_tvalid = 1;
            s_axis_tdata_owner_programID = owner_programID;
            s_axis_tdata_read_dependencies = read_dependencies;
            s_axis_tdata_write_dependencies = write_dependencies;
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            s_axis_tvalid = 0;
        end
    endtask
    
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
    

    
    // Test stimulus
    initial begin
        integer i;  // Declare loop variable
        
        // Initialize signals
        s_axis_tvalid = 0;
        s_axis_tdata_owner_programID = 0;
        s_axis_tdata_read_dependencies = 0;
        s_axis_tdata_write_dependencies = 0;
        m_axis_tready = 1;
        timeout_counter = 0;
        total_transactions = 0;
        
        $dumpfile("build/svm_scheduler.vcd");
        $dumpvars(0, tb_svm_scheduler);

        // Display the batch_owner_programID array
        $display("Initial batch_owner_programID values:");
        for (i = 0; i < MAX_BATCH_SIZE; i = i + 1) begin
            $display("batch_owner_programID[%0d] = %h", i, tb_svm_scheduler.svm_scheduler.batch_inst.batch_owner_programID[i]);
        end
        
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
            {{(MAX_DEPENDENCIES-1){1'b0}}, 1'b1},  // Read from region 0
            {{(MAX_DEPENDENCIES-2){1'b0}}, 2'b10}   // Write to region 1
        );
        repeat(10) @(posedge clk);
        
        // Transaction 2: Read from region 2, write to region 3
        $display("Submitting transaction 2 at time %0t", $time);
        submit_transaction(
            64'h2,
            {{(MAX_DEPENDENCIES-3){1'b0}}, 3'b100},  // Read from region 2
            {{(MAX_DEPENDENCIES-4){1'b0}}, 4'b1000}   // Write to region 3
        );
        repeat(10) @(posedge clk);
        
        // Transaction 3: Read from region 4, write to region 5
        $display("Submitting transaction 3 at time %0t", $time);
        submit_transaction(
            64'h3,
            {{(MAX_DEPENDENCIES-5){1'b0}}, 5'b10000},  // Read from region 4
            {{(MAX_DEPENDENCIES-6){1'b0}}, 6'b100000}   // Write to region 5
        );
        repeat(10) @(posedge clk);
        
        // Test Case 2: RAW (Read-After-Write) conflicts
        $display("\nTest Case 2: RAW (Read-After-Write) conflicts");
        $display("Submitting 3 transactions with RAW conflicts");
        
        // Transaction 4: Write to region 6
        submit_transaction(
            64'h4,
            {MAX_DEPENDENCIES{1'b0}},     // No reads
            {{(MAX_DEPENDENCIES-7){1'b0}}, 7'b1000000}     // Write to region 6
        );
        repeat(10) @(posedge clk);
        
        // Transaction 5: Read from region 6 (RAW conflict)
        submit_transaction(
            64'h5,
            {{(MAX_DEPENDENCIES-7){1'b0}}, 7'b1000000},    // Read from region 6
            {MAX_DEPENDENCIES{1'b0}}      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Transaction 6: Read from region 6 (RAW conflict)
        submit_transaction(
            64'h6,
            {{(MAX_DEPENDENCIES-7){1'b0}}, 7'b1000000},    // Read from region 6
            {MAX_DEPENDENCIES{1'b0}}      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Test Case 3: Mixed conflicting and non-conflicting transactions
        $display("\nTest Case 3: Mixed conflicting and non-conflicting transactions");
        $display("Submitting 4 transactions alternating between conflict and no conflict");
        
        // Transaction 7: Write to region 7
        submit_transaction(
            64'h7,
            {MAX_DEPENDENCIES{1'b0}},     // No reads
            {{(MAX_DEPENDENCIES-8){1'b0}}, 8'b10000000}     // Write to region 7
        );
        repeat(10) @(posedge clk);
        
        // Transaction 8: Read from region 8 (no conflict)
        submit_transaction(
            64'h8,
            {{(MAX_DEPENDENCIES-9){1'b0}}, 9'b100000000},   // Read from region 8
            {MAX_DEPENDENCIES{1'b0}}      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Transaction 9: Read from region 7 (RAW conflict)
        submit_transaction(
            64'h9,
            {{(MAX_DEPENDENCIES-8){1'b0}}, 8'b10000000},    // Read from region 7
            {MAX_DEPENDENCIES{1'b0}}      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Transaction 10: Write to region 9 (no conflict)
        submit_transaction(
            64'h10,
            {MAX_DEPENDENCIES{1'b0}},     // No reads
            {{(MAX_DEPENDENCIES-10){1'b0}}, 10'b1000000000}    // Write to region 9
        );
        repeat(10) @(posedge clk);
        
        // Test Case 4: WAW (Write-After-Write) conflicts
        $display("\nTest Case 4: WAW (Write-After-Write) conflicts");
        $display("Submitting transactions with WAW conflicts");
        
        // Transaction 11: Write to region 10
        submit_transaction(
            64'h11,
            {MAX_DEPENDENCIES{1'b0}},     // No reads
            {{(MAX_DEPENDENCIES-11){1'b0}}, 11'b10000000000}    // Write to region 10
        );
        repeat(10) @(posedge clk);
        
        // Transaction 12: Write to region 10 (WAW conflict)
        submit_transaction(
            64'h12,
            {MAX_DEPENDENCIES{1'b0}},     // No reads
            {{(MAX_DEPENDENCIES-11){1'b0}}, 11'b10000000000}    // Write to region 10 (conflicts with Transaction 11)
        );
        repeat(10) @(posedge clk);
        
        // Transaction 13: Write to region 11 (no conflict)
        submit_transaction(
            64'h13,
            {MAX_DEPENDENCIES{1'b0}},     // No reads
            {{(MAX_DEPENDENCIES-12){1'b0}}, 12'b100000000000}    // Write to region 11
        );
        repeat(10) @(posedge clk);
        
        // Test Case 5: WAR (Write-After-Read) conflicts
        $display("\nTest Case 5: WAR (Write-After-Read) conflicts");
        $display("Submitting transactions with WAR conflicts");
        
        // Transaction 14: Read from region 12
        submit_transaction(
            64'h14,
            {{(MAX_DEPENDENCIES-13){1'b0}}, 13'b1000000000000},  // Read from region 12
            {MAX_DEPENDENCIES{1'b0}}      // No writes
        );
        repeat(10) @(posedge clk);
        
        // Transaction 15: Write to region 12 (WAR conflict)
        submit_transaction(
            64'h15,
            {MAX_DEPENDENCIES{1'b0}},     // No reads
            {{(MAX_DEPENDENCIES-13){1'b0}}, 13'b1000000000000}   // Write to region 12 (conflicts with Transaction 14 read)
        );
        repeat(10) @(posedge clk);
        
        // Test Case 6: Multiple conflict types
        $display("\nTest Case 6: Multiple conflict types");
        $display("Submitting transactions with multiple conflict types");
        
        // Transaction 16: Read from region 13, Write to region 14
        submit_transaction(
            64'h16,
            {{(MAX_DEPENDENCIES-14){1'b0}}, 14'b10000000000000},  // Read from region 13
            {{(MAX_DEPENDENCIES-15){1'b0}}, 15'b100000000000000}   // Write to region 14
        );
        repeat(10) @(posedge clk);
        
        // Transaction 17: Read from region 14, Write to region 13
        // This creates both RAW (reads region 14 which Transaction 16 wrote to)
        // and WAR (writes to region 13 which Transaction 16 read from)
        submit_transaction(
            64'h17,
            {{(MAX_DEPENDENCIES-15){1'b0}}, 15'b100000000000000},  // Read from region 14 (RAW conflict with Transaction 16)
            {{(MAX_DEPENDENCIES-14){1'b0}}, 14'b10000000000000}   // Write to region 13 (WAR conflict with Transaction 16)
        );
        repeat(10) @(posedge clk);
        
        // Wait for processing
        repeat(100) @(posedge clk);

        // Test Case 4: Advanced Dependency Pattern Testing
        $display("\nTest Case 4: Advanced Dependency Pattern Testing");

        // Test 4.1: Chained Dependencies (A→B→C)
        $display("\nTest 4.1: Chained Dependencies");
        // Transaction A: Write to region 20
        submit_transaction(
            64'h20,
            {MAX_DEPENDENCIES{1'b0}},  // No reads
            {{(MAX_DEPENDENCIES-21){1'b0}}, 21'b100000000000000000000}  // Write to region 20
        );
        repeat(5) @(posedge clk);

        // Transaction B: Read from 20, Write to 21
        submit_transaction(
            64'h21,
            {{(MAX_DEPENDENCIES-21){1'b0}}, 21'b100000000000000000000},  // Read from region 20
            {{(MAX_DEPENDENCIES-22){1'b0}}, 22'b1000000000000000000000}  // Write to region 21
        );
        repeat(5) @(posedge clk);

        // Transaction C: Read from 21, Write to 22
        submit_transaction(
            64'h22,
            {{(MAX_DEPENDENCIES-22){1'b0}}, 22'b1000000000000000000000},  // Read from region 21
            {{(MAX_DEPENDENCIES-23){1'b0}}, 23'b10000000000000000000000}  // Write to region 22
        );
        repeat(10) @(posedge clk);

        // Test 4.2: Circular Dependencies
        $display("\nTest 4.2: Circular Dependencies");
        // Transaction D: Write to region 30
        submit_transaction(
            64'h30,
            {MAX_DEPENDENCIES{1'b0}},  // No reads
            {{(MAX_DEPENDENCIES-31){1'b0}}, 31'b1000000000000000000000000000000}  // Write to region 30
        );
        repeat(5) @(posedge clk);

        // Transaction E: Read from 30, Write to 31
        submit_transaction(
            64'h31,
            {{(MAX_DEPENDENCIES-31){1'b0}}, 31'b1000000000000000000000000000000},  // Read from region 30
            {{(MAX_DEPENDENCIES-32){1'b0}}, 32'b10000000000000000000000000000000}  // Write to region 31
        );
        repeat(5) @(posedge clk);

        // Transaction F: Read from 31, Write to 30 (creates circular dependency)
        submit_transaction(
            64'h32,
            {{(MAX_DEPENDENCIES-32){1'b0}}, 32'b10000000000000000000000000000000},  // Read from region 31
            {{(MAX_DEPENDENCIES-31){1'b0}}, 31'b1000000000000000000000000000000}  // Write to region 30
        );
        repeat(10) @(posedge clk);

        // Test 4.3: Overlapping Read/Write Regions
        $display("\nTest 4.3: Overlapping Read/Write Regions");
        // Transaction G: Read/Write overlapping regions 40-43
        submit_transaction(
            64'h40,
            {{(MAX_DEPENDENCIES-44){1'b0}}, 44'b11110000000000000000000000000000000000000000},  // Read 40-43
            {{(MAX_DEPENDENCIES-44){1'b0}}, 44'b00001111000000000000000000000000000000000000}   // Write 40-43
        );
        repeat(5) @(posedge clk);

        // Transaction H: Read/Write overlapping regions 42-45
        submit_transaction(
            64'h41,
            {{(MAX_DEPENDENCIES-46){1'b0}}, 46'b1111000000000000000000000000000000000000000000},  // Read 42-45
            {{(MAX_DEPENDENCIES-46){1'b0}}, 46'b0000111100000000000000000000000000000000000000}   // Write 42-45
        );
        repeat(10) @(posedge clk);

        // Test 4.4: Sparse Dependency Pattern
        $display("\nTest 4.4: Sparse Dependency Pattern");
        // Transaction I: Sparse read/write pattern
        submit_transaction(
            64'h50,
            {{(MAX_DEPENDENCIES-64){1'b0}}, 64'b1000000010000000100000001000000010000000100000001000000010000000},  // Sparse reads
            {{(MAX_DEPENDENCIES-64){1'b0}}, 64'b0100000001000000010000000100000001000000010000000100000001000000}   // Sparse writes
        );
        repeat(5) @(posedge clk);

        // Transaction J: Complementary sparse pattern
        submit_transaction(
            64'h51,
            {{(MAX_DEPENDENCIES-64){1'b0}}, 64'b0100000001000000010000000100000001000000010000000100000001000000},  // Complementary reads
            {{(MAX_DEPENDENCIES-64){1'b0}}, 64'b1000000010000000100000001000000010000000100000001000000010000000}   // Complementary writes
        );
        repeat(10) @(posedge clk);

        // Test 4.5: Dense Dependency Pattern
        $display("\nTest 4.5: Dense Dependency Pattern");
        // Transaction K: Dense read pattern
        submit_transaction(
            64'h60,
            {{(MAX_DEPENDENCIES-32){1'b0}}, 32'b11111111111111111111111111111111},  // Dense reads
            {MAX_DEPENDENCIES{1'b0}}  // No writes
        );
        repeat(5) @(posedge clk);

        // Transaction L: Dense write pattern to same region
        submit_transaction(
            64'h61,
            {MAX_DEPENDENCIES{1'b0}},  // No reads
            {{(MAX_DEPENDENCIES-32){1'b0}}, 32'b11111111111111111111111111111111}  // Dense writes
        );
        repeat(10) @(posedge clk);

        // Wait for processing
        repeat(100) @(posedge clk);

        // Test Case 5: Comprehensive Backpressure Testing
        $display("\nTest Case 4: Comprehensive Backpressure Testing");
        $display("Testing insertion stage queuing under various backpressure scenarios");

        // Phase 1: Fill batch and verify initial state
        $display("\nPhase 1: Filling batch with MAX_BATCH_SIZE transactions");
        for (i = 0; i < MAX_BATCH_SIZE; i = i + 1) begin
            case (i)
                0: submit_transaction(64'h20, {{(MAX_DEPENDENCIES-1){1'b0}}, 1'b1}, {MAX_DEPENDENCIES{1'b0}});
                1: submit_transaction(64'h21, {{(MAX_DEPENDENCIES-2){1'b0}}, 2'b11}, {MAX_DEPENDENCIES{1'b0}});
                2: submit_transaction(64'h22, {{(MAX_DEPENDENCIES-3){1'b0}}, 3'b111}, {MAX_DEPENDENCIES{1'b0}});
                3: submit_transaction(64'h23, {{(MAX_DEPENDENCIES-4){1'b0}}, 4'b1111}, {MAX_DEPENDENCIES{1'b0}});
            endcase
            repeat(2) @(posedge clk);
        end
        $display("Batch filled. Queue occupancy: %0d", queue_occupancy);

        // Phase 2: Test rapid submission during backpressure
        $display("\nPhase 2: Testing rapid submission during backpressure");
        m_axis_tready = 0;
        repeat(5) @(posedge clk);
        $display("Initial queue occupancy: %0d", queue_occupancy);

        // Submit transactions rapidly (minimal delay)
        $display("Submitting transactions rapidly:");
        for (i = 0; i < 4; i = i + 1) begin
            case (i)
                0: submit_transaction(64'h30, {{(MAX_DEPENDENCIES-4){1'b0}}, 4'b1111}, {MAX_DEPENDENCIES{1'b0}});
                1: submit_transaction(64'h31, {{(MAX_DEPENDENCIES-5){1'b0}}, 5'b11111}, {MAX_DEPENDENCIES{1'b0}});
                2: submit_transaction(64'h32, {{(MAX_DEPENDENCIES-6){1'b0}}, 6'b111111}, {MAX_DEPENDENCIES{1'b0}});
                3: submit_transaction(64'h33, {{(MAX_DEPENDENCIES-7){1'b0}}, 7'b1111111}, {MAX_DEPENDENCIES{1'b0}});
            endcase
            @(posedge clk);
            $display("Queue occupancy after rapid submission %0d (0x%0h): %0d", i, 48+i, queue_occupancy);
        end

        // Phase 3: Test queue near capacity
        $display("\nPhase 3: Testing queue near capacity");
        repeat(5) @(posedge clk);
        $display("Queue occupancy before capacity test: %0d", queue_occupancy);

        // Try to fill queue to capacity
        for (i = 0; i < 8; i = i + 1) begin
            case (i)
                0: submit_transaction(64'h40, {{(MAX_DEPENDENCIES-8){1'b0}}, 8'b11111111}, {MAX_DEPENDENCIES{1'b0}});
                1: submit_transaction(64'h41, {{(MAX_DEPENDENCIES-9){1'b0}}, 9'b111111111}, {MAX_DEPENDENCIES{1'b0}});
                2: submit_transaction(64'h42, {{(MAX_DEPENDENCIES-10){1'b0}}, 10'b1111111111}, {MAX_DEPENDENCIES{1'b0}});
                3: submit_transaction(64'h43, {{(MAX_DEPENDENCIES-11){1'b0}}, 11'b11111111111}, {MAX_DEPENDENCIES{1'b0}});
                4: submit_transaction(64'h44, {{(MAX_DEPENDENCIES-12){1'b0}}, 12'b111111111111}, {MAX_DEPENDENCIES{1'b0}});
                5: submit_transaction(64'h45, {{(MAX_DEPENDENCIES-13){1'b0}}, 13'b1111111111111}, {MAX_DEPENDENCIES{1'b0}});
                6: submit_transaction(64'h46, {{(MAX_DEPENDENCIES-14){1'b0}}, 14'b11111111111111}, {MAX_DEPENDENCIES{1'b0}});
                7: submit_transaction(64'h47, {{(MAX_DEPENDENCIES-15){1'b0}}, 15'b111111111111111}, {MAX_DEPENDENCIES{1'b0}});
            endcase
            repeat(2) @(posedge clk);
            $display("Queue occupancy during capacity test %0d (0x%0h): %0d", i, 64+i, queue_occupancy);
        end

        // Phase 4: Test queue drain behavior
        $display("\nPhase 4: Testing queue drain behavior");
        $display("Queue occupancy before drain: %0d", queue_occupancy);

        // Release backpressure and monitor drain rate
        m_axis_tready = 1;
        for (i = 0; i < 5; i = i + 1) begin
            repeat(2) @(posedge clk);
            $display("Queue occupancy during drain cycle %0d: %0d", i, queue_occupancy);
        end

        // Phase 5: Test mixed backpressure patterns
        $display("\nPhase 5: Testing mixed backpressure patterns");
        
        // Pattern: Ready-NotReady-Ready-NotReady
        for (i = 0; i < 4; i = i + 1) begin
            m_axis_tready = ~m_axis_tready;
            case (i)
                0: submit_transaction(64'h50, {{(MAX_DEPENDENCIES-16){1'b0}}, 16'b1111111111111111}, {MAX_DEPENDENCIES{1'b0}});
                1: submit_transaction(64'h51, {{(MAX_DEPENDENCIES-17){1'b0}}, 17'b11111111111111111}, {MAX_DEPENDENCIES{1'b0}});
                2: submit_transaction(64'h52, {{(MAX_DEPENDENCIES-18){1'b0}}, 18'b111111111111111111}, {MAX_DEPENDENCIES{1'b0}});
                3: submit_transaction(64'h53, {{(MAX_DEPENDENCIES-19){1'b0}}, 19'b1111111111111111111}, {MAX_DEPENDENCIES{1'b0}});
            endcase
            repeat(3) @(posedge clk);
            $display("Queue occupancy during pattern %0d (ready=%0d): %0d", i, m_axis_tready, queue_occupancy);
        end

        // Final drain
        $display("\nFinal queue drain");
        m_axis_tready = 1;
        repeat(20) @(posedge clk);
        $display("Final queue occupancy: %0d", queue_occupancy);
        
        // Wait for any pending transactions to complete
        repeat(10) @(posedge clk);
        
        // Wait for any final transactions to be counted
        repeat(5) @(posedge clk);
        
        // Display final test results
        $display("\nTest Results:");
        $display("Raw Conflicts: %0d", raw_conflicts);
        $display("WAW Conflicts: %0d", waw_conflicts);
        $display("WAR Conflicts: %0d", war_conflicts);
        $display("Total Conflicts: %0d", raw_conflicts + waw_conflicts + war_conflicts);
        $display("Rejected Transactions: %0d", filter_hits);
        $display("Final Queue Occupancy: %0d", queue_occupancy);
        $display("\nBatch Statistics:");
        $display("  Total Transactions Submitted: %0d", total_transactions);
        $display("  Total Transactions in Batches: %0d", total_batched_transactions);
        $display("  Total Batches Created: %0d", total_batches);
        $display("  Full Batches: %0d (%.1f%%)", full_batches,
                 full_batches * 100.0 / (total_batches > 0 ? total_batches : 1));
        $display("  Empty Batches: %0d (%.1f%%)", empty_batches,
                 empty_batches * 100.0 / (total_batches > 0 ? total_batches : 1));
        $display("  Max Transactions in a Batch: %0d", max_batch_transactions);
        $display("  Average Transactions per Batch: %.2f",
                 total_batched_transactions / (total_batches > 0 ? total_batches : 1));
        $display("\nBatch Timing (in clock cycles):");
        $display("  Average Batch Time: %0d cycles",
                 total_batch_time / (total_batches > 0 ? total_batches : 1));
        $display("  Min Batch Time: %0d cycles", min_batch_time);
        $display("  Max Batch Time: %0d cycles", max_batch_time);
        $display("  Total Time in Batches: %0d cycles", total_batch_time);
        
        // End simulation
        #100 $finish;
    end

endmodule
