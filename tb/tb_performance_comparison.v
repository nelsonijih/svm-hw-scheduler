module tb_performance_comparison;

    // Parameters
    parameter MAX_DEPENDENCIES = 1024;
    parameter MAX_BATCH_SIZE = 8;
    parameter BATCH_TIMEOUT_CYCLES = 100;
    parameter MAX_PENDING_TRANSACTIONS = 16;
    parameter INSERTION_QUEUE_DEPTH = 8;
    parameter NUM_TEST_TRANSACTIONS = 100;
    parameter CONFLICT_RATE = 30; // 30% conflict rate
    
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
    
    // Performance metrics
    integer cycle_count;
    integer transaction_count;
    integer accepted_count;
    integer rejected_count;
    integer start_time;
    integer end_time;
    
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
    
    // Random number generation for dependencies
    function [1023:0] random_dependency;
        input integer seed;
        integer i;
        begin
            random_dependency = 0;
            for (i = 0; i < 32; i = i + 1) begin
                // Set random bits in the dependency vector
                // We only set a few bits to simulate realistic memory access patterns
                random_dependency[($random(seed) % 1024)] = 1'b1;
            end
        end
    endfunction
    
    // Generate a transaction with potential conflict
    task generate_transaction;
        input integer transaction_id;
        input integer conflict_type; // 0=none, 1=RAW, 2=WAW, 3=WAR
        input [1023:0] batch_read_deps;
        input [1023:0] batch_write_deps;
        output [1023:0] read_deps;
        output [1023:0] write_deps;
        reg [1023:0] base_read_deps;
        reg [1023:0] base_write_deps;
        integer conflict_bit;
        begin
            // Generate random base dependencies
            base_read_deps = random_dependency(transaction_id);
            base_write_deps = random_dependency(transaction_id + 10000);
            
            // Add conflict if requested
            if (conflict_type > 0) begin
                case (conflict_type)
                    1: begin // RAW conflict
                        // Find a bit that's set in batch_write_deps
                        conflict_bit = $random % 1024;
                        while (batch_write_deps[conflict_bit] != 1'b1 && conflict_bit < 1024) begin
                            conflict_bit = (conflict_bit + 1) % 1024;
                        end
                        // Set the same bit in read_deps to create RAW conflict
                        base_read_deps[conflict_bit] = 1'b1;
                    end
                    2: begin // WAW conflict
                        // Find a bit that's set in batch_write_deps
                        conflict_bit = $random % 1024;
                        while (batch_write_deps[conflict_bit] != 1'b1 && conflict_bit < 1024) begin
                            conflict_bit = (conflict_bit + 1) % 1024;
                        end
                        // Set the same bit in write_deps to create WAW conflict
                        base_write_deps[conflict_bit] = 1'b1;
                    end
                    3: begin // WAR conflict
                        // Find a bit that's set in batch_read_deps
                        conflict_bit = $random % 1024;
                        while (batch_read_deps[conflict_bit] != 1'b1 && conflict_bit < 1024) begin
                            conflict_bit = (conflict_bit + 1) % 1024;
                        end
                        // Set the same bit in write_deps to create WAR conflict
                        base_write_deps[conflict_bit] = 1'b1;
                    end
                endcase
            end
            
            read_deps = base_read_deps;
            write_deps = base_write_deps;
        end
    endtask
    
    // Test procedure
    integer i;
    integer wait_cycles;
    integer conflict_type;
    reg [1023:0] current_batch_read_deps;
    reg [1023:0] current_batch_write_deps;
    reg [1023:0] gen_read_deps;
    reg [1023:0] gen_write_deps;
    
    initial begin
        // Dump waveforms
        $dumpfile("performance_comparison.vcd");
        $dumpvars(0, tb_performance_comparison);
        
        // Initialize signals
        rst_n = 0;
        s_axis_tvalid = 0;
        s_axis_tdata_owner_programID = 0;
        s_axis_tdata_read_dependencies = 0;
        s_axis_tdata_write_dependencies = 0;
        m_axis_tready = 1;
        
        // Initialize performance metrics
        cycle_count = 0;
        transaction_count = 0;
        accepted_count = 0;
        rejected_count = 0;
        current_batch_read_deps = 0;
        current_batch_write_deps = 0;
        
        // Reset for a few cycles
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        
        $display("Starting performance comparison test with %d transactions", NUM_TEST_TRANSACTIONS);
        $display("Target conflict rate: %d%%", CONFLICT_RATE);
        
        // Record start time
        start_time = $time;
        
        // Submit transactions
        for (i = 0; i < NUM_TEST_TRANSACTIONS; i = i + 1) begin
            // Wait for ready
            wait_cycles = 0;
            while (!s_axis_tready && wait_cycles < 1000) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
                cycle_count = cycle_count + 1;
            end
            
            if (wait_cycles >= 1000) begin
                $display("Error: Timeout waiting for s_axis_tready");
                $finish;
            end
            
            // Determine if this transaction should have a conflict
            if ($random % 100 < CONFLICT_RATE) begin
                conflict_type = ($random % 3) + 1; // 1=RAW, 2=WAW, 3=WAR
            end else begin
                conflict_type = 0; // No conflict
            end
            
            // Generate transaction
            generate_transaction(i, conflict_type, current_batch_read_deps, current_batch_write_deps, 
                                gen_read_deps, gen_write_deps);
            
            // Submit transaction
            s_axis_tvalid = 1;
            s_axis_tdata_owner_programID = i + 1; // Transaction ID
            s_axis_tdata_read_dependencies = gen_read_deps;
            s_axis_tdata_write_dependencies = gen_write_deps;
            
            $display("Submitting transaction %d at time %0t", i, $time);
            $display("  Conflict type: %d (0=none, 1=RAW, 2=WAW, 3=WAR)", conflict_type);
            
            @(posedge clk);
            s_axis_tvalid = 0;
            transaction_count = transaction_count + 1;
            
            // Update batch dependencies for simulation tracking
            // Note: This is simplified; the actual hardware updates these when transactions are accepted
            if (conflict_type == 0) begin
                current_batch_read_deps = current_batch_read_deps | gen_read_deps;
                current_batch_write_deps = current_batch_write_deps | gen_write_deps;
            end
            
            // Wait a few cycles between transactions
            repeat (2) @(posedge clk);
            cycle_count = cycle_count + 2;
        end
        
        // Wait for all transactions to be processed
        repeat (1000) @(posedge clk);
        cycle_count = cycle_count + 1000;
        
        // Record end time
        end_time = $time;
        
        // Calculate performance metrics
        accepted_count = transactions_processed;
        rejected_count = filter_hits;
        
        // Display results
        $display("\nPerformance Test Results:");
        $display("  Total transactions:       %d", transaction_count);
        $display("  Accepted transactions:    %d", accepted_count);
        $display("  Rejected transactions:    %d", rejected_count);
        $display("  Actual conflict rate:     %0.2f%%", (rejected_count * 100.0) / transaction_count);
        $display("  RAW conflicts:            %d", raw_conflicts);
        $display("  WAW conflicts:            %d", waw_conflicts);
        $display("  WAR conflicts:            %d", war_conflicts);
        $display("  Total cycles:             %d", cycle_count);
        $display("  Throughput:               %0.2f transactions/cycle", transaction_count / (cycle_count * 1.0));
        $display("  Execution time:           %0t", end_time - start_time);
        
        $finish;
    end
    
    // Monitor output transactions
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            $display("Transaction accepted at time %0t", $time);
            $display("  Owner ID: %h", m_axis_tdata_owner_programID);
        end
    end

endmodule
