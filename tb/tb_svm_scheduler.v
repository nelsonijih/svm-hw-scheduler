///////////////
// test bench - instantiate the top system, and drive test signals/data to design.
//////////////

`timescale 1ns/1ps

module tb_svm_scheduler();
    // Params for the design.
    parameter MAX_TRANSACTIONS = 48;
    parameter DEPS_PER_TRANSACTION = 1024;
    parameter TABLE_SIZE = MAX_TRANSACTIONS * DEPS_PER_TRANSACTION;
    
    // test bench variables
    integer i;
    integer wait_cycles;
    
    //Clk and rst sigs
    reg clk;
    reg rst_n;
    
    // Test inputs
    reg [63:0] owner_programID;
    reg [DEPS_PER_TRANSACTION*64-1:0] read_dependencies;
    reg [DEPS_PER_TRANSACTION*64-1:0] write_dependencies;
    reg transaction_valid;
    
    // Test outputs
    wire transaction_accepted;
    wire [63:0] inserted_programID;
    wire has_conflict;
    wire [63:0] conflicting_id;
    
    // continous clock gen to drive design.
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 10ns period.
    end
    
    // Instantiate the top module
    top svm_hw_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .owner_programID(owner_programID),
        .read_dependencies(read_dependencies),
        .write_dependencies(write_dependencies),
        .transaction_valid(transaction_valid),
        .transaction_accepted(transaction_accepted),
        .inserted_programID(inserted_programID),
        .has_conflict(has_conflict),
        .conflicting_id(conflicting_id)
    );
    
    // Init dependencies to zero
    task clear_dependencies;
        begin
            read_dependencies = 0;
            write_dependencies = 0;
        end
    endtask
    
    // Setting read_dep for testing purposes.
    task set_read_dependency;
        input [63:0] addr;
        begin
            read_dependencies[addr] = 1'b1;
        end
    endtask

    // set bit in write_dep
    task set_write_dependency;
        input [63:0] addr;
        begin
            write_dependencies[addr] = 1'b1;
        end
    endtask

    //Wait for transaction acceptance or conflict task.
    task wait_for_acceptance;
        begin
            @(posedge clk);
            while (!transaction_accepted && !has_conflict) begin
                @(posedge clk);
            end
            if (has_conflict) begin
                $display("Transaction CONFLICT detected! Conflicting with transaction ID: %h", conflicting_id);
            end else begin
                $display("Transaction ACCEPTED! Inserted Program ID: %h", inserted_programID);
            end
        end
    endtask

    // Task to display dependency info
    task display_dependencies;
        input [63:0] prog_id;
        integer i;
        begin
            $display("Transaction %h Details:", prog_id);
            $display("  Read Dependencies:");
            for (i = 0; i < DEPS_PER_TRANSACTION; i = i + 1) begin
                if (read_dependencies[i*64 +: 64] != 0)
                    $display("    - Address %0d", i);
            end
            $display("  Write Dependencies:");
            for (i = 0; i < DEPS_PER_TRANSACTION; i = i + 1) begin
                if (write_dependencies[i*64 +: 64] != 0)
                    $display("    - Address %0d", i);
            end
        end
    endtask

    // Task to submit transaction and wait for acceptance
    task submit_transaction;
        input [63:0] prog_id;
        begin
            @(posedge clk);
            owner_programID = prog_id;
            transaction_valid = 1;
            wait_for_acceptance();
            if (has_conflict) begin
                $display("\n[CONFLICT] Transaction %h blocked due to dependency conflict", prog_id);
                display_dependencies(prog_id);
                $display("----------------------------------------");
            end
            else
                $display("[ACCEPTED] Transaction %h accepted", prog_id);
        end
    endtask

    // Task to set a specific dependency
    task set_dependency;
        input [9:0] index;
        input [63:0] value;
        input is_read;
        begin
            if (is_read) begin
                read_dependencies[index*64 +: 64] = value;
            end else begin
                write_dependencies[index*64 +: 64] = value;
            end
        end
    endtask
    
    // Test stimulus
    initial begin
        // Initialize waveform dumping
        $dumpfile("svm_scheduler.vcd");
        $dumpvars(0, tb_svm_scheduler);
        
        // Initialize inputs
        rst_n = 0;
        transaction_valid = 0;
        owner_programID = 0;
        clear_dependencies();
        
        // Wait 100ns and release reset
        #100 rst_n = 1;
        
        // Test1 to test RAW Hazard
        // Transaction1 - create a write dep to address 5
        $display("\nTest Case 1: RAW Hazard");
        clear_dependencies();
        set_dependency(2,5,0);
        submit_transaction(64'd1); //tx1
        //Transaction 2: create a read dep to address 5 and should cause conflict.
        $display("\nTest Case 1: Tx to trigger RAW harzard detection");
        clear_dependencies();
        set_dependency(10,5, 1);
        submit_transaction(64'd2); //tx2
        
        //Test Case 2: WAW Hazard
        //Transaction 3: creat a write_dep to address 10
        $display("\nTest Case 2: WAW Hazard");
        clear_dependencies();
        set_dependency(12,10,0);
        submit_transaction(64'd3); //tx3
        // Transaction4: create a write_dep to write to address 10 (should be blocked)
        $display("\nTest Case 2: Tx to trigger WAW harzard detection");
        clear_dependencies();
        set_dependency(15,10,0);
        submit_transaction(64'd4); //tx4
        
        // Test Case 3: WAR Hazard
        // Transaction5 - create a read_dep from address 15
        $display("\nTest Case 3: WAR Hazard");
        clear_dependencies();
        set_read_dependency(15);
        submit_transaction(64'd5); //tx5
        // Transaction6- set write_dep to address 15 and should cause conflict.
        $display("\nTest Case 3: Tx to trigger WAR harzard detection");
        clear_dependencies();
        set_write_dependency(15);
        submit_transaction(64'd6); //tx6
        
        // Test Case 4: Non-conflicting tx
        $display("\nTest Case 4:Non-conflicting tx");
        clear_dependencies();
        submit_transaction(64'd6); //tx7
        
        // Test Case 4: Simple transaction without dependencies
        $display("\nTest Case 5: Non conficting tx");
        clear_dependencies();
        submit_transaction(64'd11); //tx8
        
      
        $display("\nTest Case 6: Transaction");
        clear_dependencies();
        set_write_dependency(11);  // No conflict read
        submit_transaction(64'd1234); //tx9
       
        $display("\nTest Case 6: Transaction ");
        clear_dependencies();
        set_write_dependency(11);  // Write dependency causing conflict.
        submit_transaction(64'd4321); //tx10

        // Delay before finishing.
        #100;
        $finish;
    end
    
    // Monitor pipeline stages
    always @(posedge clk) begin
        if (svm_hw_scheduler.filter_stage.filter_ready)
            $display("Time %0t: Filter stage approved transaction %h", $time, svm_hw_scheduler.filter_stage.owner_programID);
            
        if (svm_hw_scheduler.insertion_stage.insertion_ready)
            $display("Time %0t: Insertion stage ready with transaction %h", $time, svm_hw_scheduler.insertion_stage.owner_programID);
            
        if (transaction_accepted)
            $display("Time %0t: Batch stage accepted transaction %h", $time, inserted_programID);
    end

endmodule
