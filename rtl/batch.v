module batch #(
    parameter MAX_DEPENDENCIES = 256,
    parameter MAX_BATCH_SIZE = 8,
    parameter MIN_BATCH_SIZE = 2,  // Minimum transactions before timeout can trigger
    parameter BATCH_TIMEOUT_CYCLES = 100
) (
    input wire clk,
    input wire rst_n,
    
    // AXI-Stream input interface
    input wire s_axis_tvalid,
    output reg s_axis_tready,
    input wire [63:0] s_axis_tdata_owner_programID,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_read_dependencies,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_write_dependencies,
    
    // AXI-Stream output interface
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg [63:0] m_axis_tdata_owner_programID,
    output reg [MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies,
    output reg [MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies,
    
    // Batch completion signal
    output reg batch_completed,
    
    // Performance monitoring
    output reg [31:0] transactions_processed,
    output wire transaction_accepted
);

    // FSM states
    localparam IDLE = 2'b00;
    localparam COLLECT = 2'b01;
    localparam OUTPUT = 2'b10;
    reg [1:0] state;
    
    // Batch storage
    reg [63:0] batch_owner_programID [0:MAX_BATCH_SIZE-1];
    reg [MAX_DEPENDENCIES-1:0] batch_read_deps [0:MAX_BATCH_SIZE-1];
    reg [MAX_DEPENDENCIES-1:0] batch_write_deps [0:MAX_BATCH_SIZE-1];
    reg [3:0] batch_count;
    reg [3:0] output_index;
    
    // Timeout counter
    reg [31:0] timeout_counter;
    
    // Debug counter
    reg [31:0] debug_cycles;
    
    // Transaction accepted when valid handshake occurs
    assign transaction_accepted = s_axis_tvalid && s_axis_tready;
    
    // Main control logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            s_axis_tready <= 1'b1;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata_owner_programID <= 64'd0;
            m_axis_tdata_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            m_axis_tdata_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            
            batch_count <= 4'd0;
            output_index <= 4'd0;
            timeout_counter <= 32'd0;
            transactions_processed <= 32'd0;
            debug_cycles <= 32'd0;
            batch_completed <= 1'b0;
        end
        else begin
            // Increment debug counter
            debug_cycles <= debug_cycles + 1'b1;
            
            // Default assignments
            s_axis_tready <= 1'b0;
            batch_completed <= 1'b0; // Default to not completed
            
            case (state)
                IDLE: begin
                    // Reset batch state for a new batch
                    batch_count <= 4'd0;
                    output_index <= 4'd0;
                    timeout_counter <= 32'd0;
                    
                    // Ready to accept new transaction
                    s_axis_tready <= 1'b1;
                    m_axis_tvalid <= 1'b0;
                    
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Store first transaction
                        batch_owner_programID[0] <= s_axis_tdata_owner_programID;
                        batch_read_deps[0] <= s_axis_tdata_read_dependencies;
                        batch_write_deps[0] <= s_axis_tdata_write_dependencies;
                        
                        batch_count <= 4'd1;
                        state <= COLLECT;
                    end
                end
                
                COLLECT: begin
                    // Increment timeout counter
                    timeout_counter <= timeout_counter + 1'b1;
                    
                    // Only accept new transactions if we have space
                    s_axis_tready <= (batch_count < MAX_BATCH_SIZE);
                    
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (batch_count >= MAX_BATCH_SIZE) begin
                            // Safety check - should never happen due to s_axis_tready condition
                            $display("ERROR: Attempting to add transaction when batch_count (%0d) >= MAX_BATCH_SIZE (%0d)", batch_count, MAX_BATCH_SIZE);
                            state <= OUTPUT;
                            output_index <= 4'd0;
                        end else begin
                            // Store transaction in batch
                            batch_owner_programID[batch_count] <= s_axis_tdata_owner_programID;
                            batch_read_deps[batch_count] <= s_axis_tdata_read_dependencies;
                            batch_write_deps[batch_count] <= s_axis_tdata_write_dependencies;
                            
                            // Update batch count and reset timeout
                            batch_count <= batch_count + 1'b1;
                            timeout_counter <= 32'd0;
                            
                            // Debug output
                            $display("\nAdding transaction to batch:");
                            $display("  Current batch size: %0d", batch_count);
                            $display("  Max batch size: %0d", MAX_BATCH_SIZE);
                            
                            // If this transaction fills the batch, move to output
                            if (batch_count + 1'b1 >= MAX_BATCH_SIZE) begin
                                state <= OUTPUT;
                                output_index <= 4'd0;
                                $display("  Batch full - moving to OUTPUT state");
                            end
                        end
                    end
                    else if (batch_count > 0) begin
                        // Only check timeouts if we have transactions
                        if (timeout_counter >= BATCH_TIMEOUT_CYCLES && batch_count >= MIN_BATCH_SIZE) begin
                            // Normal timeout with sufficient transactions
                            state <= OUTPUT;
                            output_index <= 4'd0;
                        end
                        else if (timeout_counter >= BATCH_TIMEOUT_CYCLES * 2 && batch_count < MIN_BATCH_SIZE) begin
                            // Extended timeout for small batches
                            state <= OUTPUT;
                            output_index <= 4'd0;
                        end
                    end
                    else begin
                        // No transactions, reset timeout
                        timeout_counter <= 32'd0;
                    end
                end
                
                OUTPUT: begin
                    // Only output if we have transactions
                    if (batch_count > 0) begin
                        // Output transactions one by one
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata_owner_programID <= batch_owner_programID[output_index];
                        m_axis_tdata_read_dependencies <= batch_read_deps[output_index];
                        m_axis_tdata_write_dependencies <= batch_write_deps[output_index];
                        
                        if (m_axis_tready) begin
                            // Transaction accepted
                            transactions_processed <= transactions_processed + 1'b1;
                            
                            // Debug output
                            $display("\nOutputting transaction from batch:");
                            $display("  Transaction index: %0d", output_index);
                            $display("  Batch size: %0d", batch_count);
                            
                            if (output_index == batch_count - 1) begin
                                // All transactions in batch have been output
                                m_axis_tvalid <= 1'b0;
                                state <= IDLE;
                                s_axis_tready <= 1'b1;
                                
                                // Signal batch completion
                                batch_completed <= 1'b1;
                                
                                // Debug output
                                $display("\nBatch completed:");
                                $display("  Total transactions: %0d", batch_count);
                                $display("  Was full: %s", batch_count == MAX_BATCH_SIZE ? "yes" : "no");
                            end
                            else begin
                                // Move to next transaction in batch
                                output_index <= output_index + 1'b1;
                            end
                        end
                    end
                    else begin
                        // No transactions, go back to IDLE
                        state <= IDLE;
                        s_axis_tready <= 1'b1;
                        m_axis_tvalid <= 1'b0;
                            
                            // Print detailed batch information
                            $display("\n===============FOR SIMULATION ONLY. REMOVE FOR SYNC====================================");
                            $display("BATCH COMPLETED at time %0t", $time);
                            $display("Total transactions in batch: %0d", batch_count);
                            $display("Maximum allowed batch size: %0d", MAX_BATCH_SIZE);
                            $display("Batch completed due to: %s", 
                                batch_count >= MAX_BATCH_SIZE ? "MAX_BATCH_SIZE reached" :
                                batch_count >= MIN_BATCH_SIZE ? "Normal timeout" : "Extended timeout");
                            $display("===================================================\n");
                            
                            // Print each transaction's details
                            begin
                                integer i;
                                integer bit_idx;
                                
                                for (i = 0; i < batch_count; i = i + 1) begin
                                    $display("Transaction %0d:", i);
                                    $display("  Owner Program ID: 0x%h", batch_owner_programID[i]);
                                    
                                    // Print read dependencies (only non-zero bits for clarity)
                                    $display("  Read Dependencies:");
                                    for (bit_idx = 0; bit_idx < MAX_DEPENDENCIES; bit_idx = bit_idx + 1) begin
                                        if (batch_read_deps[i][bit_idx]) begin
                                            $display("    Bit %0d: 1", bit_idx);
                                        end
                                    end
                                    
                                    // Print write dependencies (only non-zero bits for clarity)
                                    $display("  Write Dependencies:");
                                    for (bit_idx = 0; bit_idx < MAX_DEPENDENCIES; bit_idx = bit_idx + 1) begin
                                        if (batch_write_deps[i][bit_idx]) begin
                                            $display("    Bit %0d: 1", bit_idx);
                                        end
                                    end
                                    $display("");
                                end
                            end
                            
                            // Print batch cumulative dependencies
                            $display("Batch Cumulative Dependencies:");
                            
                            begin
                                integer i;
                                integer bit_idx;
                                reg [MAX_DEPENDENCIES-1:0] cumulative_read_deps;
                                reg [MAX_DEPENDENCIES-1:0] cumulative_write_deps;
                                
                                // Calculate and print cumulative read dependencies
                                $display("  Cumulative Read Dependencies:");
                                cumulative_read_deps = {MAX_DEPENDENCIES{1'b0}};
                                for (i = 0; i < batch_count; i = i + 1) begin
                                    cumulative_read_deps = cumulative_read_deps | batch_read_deps[i];
                                end
                                for (bit_idx = 0; bit_idx < MAX_DEPENDENCIES; bit_idx = bit_idx + 1) begin
                                    if (cumulative_read_deps[bit_idx]) begin
                                        $display("    Bit %0d: 1", bit_idx);
                                    end
                                end
                                
                                // Calculate and print cumulative write dependencies
                                $display("  Cumulative Write Dependencies:");
                                cumulative_write_deps = {MAX_DEPENDENCIES{1'b0}};
                                for (i = 0; i < batch_count; i = i + 1) begin
                                    cumulative_write_deps = cumulative_write_deps | batch_write_deps[i];
                                end
                                for (bit_idx = 0; bit_idx < MAX_DEPENDENCIES; bit_idx = bit_idx + 1) begin
                                    if (cumulative_write_deps[bit_idx]) begin
                                        $display("    Bit %0d: 1", bit_idx);
                                    end
                                end
                            end
                            
                            $display("\n================REMOVE FOR SYNTHESIS===================================");
                        end
                end
                
                default: begin
                    state <= IDLE;
                    s_axis_tready <= 1'b1;
                end
            endcase
            
            // Safety timeout - if stuck for too long, reset state
            if (debug_cycles > 1000) begin
                state <= IDLE;
                s_axis_tready <= 1'b1;
                m_axis_tvalid <= 1'b0;
                debug_cycles <= 32'd0;
            end
        end
    end
endmodule
