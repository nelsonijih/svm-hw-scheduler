module batch #(
    parameter MAX_DEPENDENCIES = 256,
    parameter MAX_BATCH_SIZE = 8,
    parameter MIN_BATCH_SIZE = 2,  // Minimum transactions before timeout can trigger
    parameter BATCH_TIMEOUT_CYCLES = 100,
    parameter DEBUG_ENABLE = 1
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
    output reg [31:0] transactions_batched,    // Total transactions in completed batches
    output wire transaction_accepted,
    output reg [31:0] batch_stall_count,       // Count of stalls in batch module
    output reg [31:0] current_batch_size,      // Current number of transactions in batch
    output reg [31:0] transactions_in_batch    // Total transactions currently in batch
);

    // FSM states
    localparam IDLE = 2'b00;
    localparam COLLECT = 2'b01;
    localparam OUTPUT = 2'b10;
    localparam FLUSH = 2'b11;  // New state for handling backpressure
    reg [1:0] state;
    reg [1:0] state_prev;  // For edge detection
    
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
    
    // Stall detection
    reg output_stall_detected;
    reg [31:0] stall_counter;
    
    // Main control logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            state_prev <= IDLE;
            s_axis_tready <= 1'b1;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata_owner_programID <= 64'd0;
            m_axis_tdata_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            m_axis_tdata_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            
            batch_count <= 4'd0;
            output_index <= 4'd0;
            timeout_counter <= 32'd0;
            transactions_batched <= 32'd0;
            debug_cycles <= 32'd0;
            transactions_in_batch <= 32'd0;
            batch_completed <= 1'b0;
            output_stall_detected <= 1'b0;
            stall_counter <= 32'd0;
            batch_stall_count <= 32'd0;
            current_batch_size <= 32'd0;
        end
        else begin
            // Update previous state for edge detection
            state_prev <= state;
            
            // Increment debug counter
            debug_cycles <= debug_cycles + 1'b1;
            
            // Default assignments
            s_axis_tready <= 1'b0;
            batch_completed <= 1'b0;
            current_batch_size <= batch_count; // Update performance counter
            
            // Reset counters when starting a new batch
            if (state == IDLE && s_axis_tvalid && s_axis_tready) begin
                // Reset batch-related counters
                batch_count <= 4'd0;
                output_index <= 4'd0;
                stall_counter <= 32'd0;
                output_stall_detected <= 1'b0;
            end
            
            // Stall detection in OUTPUT state
            if (state == OUTPUT && m_axis_tvalid && !m_axis_tready) begin
                stall_counter <= stall_counter + 1'b1;
                if (stall_counter > 10 && !output_stall_detected) begin
                    output_stall_detected <= 1'b1;
                    batch_stall_count <= batch_stall_count + 1'b1;
                    if (DEBUG_ENABLE) begin
                        $display("\nBATCH STALL DETECTED at time %0t", $time);
                        $display("  Stalled in OUTPUT state for %0d cycles", stall_counter);
                        $display("  Current batch size: %0d, Output index: %0d", batch_count, output_index);
                        $display("  Total stalls detected: %0d", batch_stall_count + 1'b1);
                    end
                end
            end else begin
                stall_counter <= 32'd0; // Reset stall counter when not stalled
            end
            
            // Debug output when transactions are successfully output
            if (state == OUTPUT && m_axis_tvalid && m_axis_tready) begin
                if (DEBUG_ENABLE) begin
                    $display("Transaction output from batch: index=%0d, batch_size=%0d", 
                             output_index, batch_count);
                    $display("  Total transactions: %0d", transactions_batched);
                end
            end
            
            // Clear batch_completed by default
            batch_completed <= 1'b0;
            
            case (state)
                IDLE: begin
                    // Reset batch state for a new batch
                    batch_count <= 4'd0;
                    output_index <= 4'd0;
                    timeout_counter <= 32'd0;
                    batch_completed <= 1'b0;
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
                            transactions_in_batch <= transactions_in_batch + 1'b1;
                            timeout_counter <= 32'd0;
                            
                            // Debug output for transaction tracking
                            if (DEBUG_ENABLE) begin
                                $display("\nAdding transaction to batch:");
                                $display("  Current batch size: %0d", batch_count + 1'b1);
                                $display("  Max batch size: %0d", MAX_BATCH_SIZE);
                                $display("  Total transactions batched: %0d", transactions_batched);
                            end
                            
                            // If this transaction fills the batch, move to output
                            if (batch_count + 1'b1 >= MAX_BATCH_SIZE) begin
                                state <= OUTPUT;
                                output_index <= 4'd0;
                                if (DEBUG_ENABLE) $display("  Batch full - moving to OUTPUT state");
                            end
                        end
                    end
                    else if (batch_count > 0) begin
                        // Only check timeouts if we have transactions
                        if (timeout_counter >= BATCH_TIMEOUT_CYCLES && batch_count >= MIN_BATCH_SIZE) begin
                            // Normal timeout with sufficient transactions
                            state <= OUTPUT;
                            output_index <= 4'd0;
                            if (DEBUG_ENABLE) $display("  Batch timeout with %0d transactions - moving to OUTPUT state", batch_count);
                        end
                        else if (timeout_counter >= BATCH_TIMEOUT_CYCLES * 2 && batch_count < MIN_BATCH_SIZE) begin
                            // Extended timeout for small batches
                            state <= OUTPUT;
                            output_index <= 4'd0;
                            if (DEBUG_ENABLE) $display("  Extended batch timeout with %0d transactions - moving to OUTPUT state", batch_count);
                        end
                    end
                    
                    // Force output if we've been collecting for too long (safety mechanism)
                    if (timeout_counter >= BATCH_TIMEOUT_CYCLES * 4) begin
                        if (batch_count > 0) begin
                            state <= OUTPUT;
                            output_index <= 4'd0;
                            if (DEBUG_ENABLE) $display("  SAFETY TIMEOUT - forcing batch output with %0d transactions", batch_count);
                        end else begin
                            // Reset if no transactions to avoid getting stuck
                            state <= IDLE;
                            timeout_counter <= 32'd0;
                            if (DEBUG_ENABLE) $display("  SAFETY TIMEOUT - resetting to IDLE with no transactions");
                        end
                    end else begin
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
                            // Debug output
                            if (DEBUG_ENABLE) begin
                                $display("\nOutputting transaction from batch:");
                                $display("  Transaction index: %0d", output_index);
                                $display("  Batch size: %0d", batch_count);
                            end
                            
                            // Update transaction count for each successful output
                            transactions_batched <= transactions_batched + 1;
                            
                            // Display transaction output
                            if (DEBUG_ENABLE) begin
                                $display("Transaction output from batch: index=%0d, batch_size=%0d", output_index, batch_count);
                                $display("  Total transactions: %0d", transactions_batched + 1);
                            end

                            if (output_index == batch_count - 1) begin
                                // All transactions in batch have been output
                                m_axis_tvalid <= 1'b0;
                                state <= IDLE;
                                s_axis_tready <= 1'b1;
                                output_index <= 4'd0;
                                batch_completed <= 1'b1;
                                output_stall_detected <= 1'b0; // Reset stall detection
                                
                                if (DEBUG_ENABLE) begin
                                    $display("\nBatch completed:");
                                    $display("  Transactions in this batch: %0d", batch_count);
                                    $display("  Total transactions in batches: %0d", transactions_batched + 1);
                                    $display("  Was full: %s", batch_count >= MAX_BATCH_SIZE ? "yes" : "no");
                                    $display("  Debug: transactions_batched=%0d", transactions_batched + 1);
                                end
                            end else begin
                                // Move to next transaction in batch
                                output_index <= output_index + 1;
                            end
                        end else if (stall_counter >= BATCH_TIMEOUT_CYCLES) begin
                            // If we've been stalled for too long, try to flush the batch
                            state <= FLUSH;
                            if (DEBUG_ENABLE) begin
                                $display("\nSEVERE STALL DETECTED - Moving to FLUSH state");
                                $display("  Stalled for %0d cycles in OUTPUT state", stall_counter);
                                $display("  Current batch size: %0d, Output index: %0d", batch_count, output_index);
                            end
                        end
                    end
                    else begin
                        // No transactions, go back to IDLE
                        state <= IDLE;
                        s_axis_tready <= 1'b1;
                        m_axis_tvalid <= 1'b0;
                        
                        // Print detailed batch information
                        if (DEBUG_ENABLE) begin
                            $display("\n===============FOR SIMULATION ONLY. REMOVE FOR SYNC====================================");
                            $display("BATCH COMPLETED at time %0t", $time);
                            $display("Total transactions in batch: %0d", batch_count);
                        end
                    end
                end
                
                FLUSH: begin
                    // Special state to handle severe stalls
                    // Keep trying to output the current transaction
                    m_axis_tvalid <= 1'b1;
                    
                    if (m_axis_tready) begin
                        // Transaction accepted, continue with normal output
                        transactions_batched <= transactions_batched + 1;
                        
                        if (DEBUG_ENABLE) begin
                            $display("\nFlushed transaction %0d from batch after stall", output_index);
                        end
                        
                        if (output_index == batch_count - 1) begin
                            // All transactions in batch have been output
                            m_axis_tvalid <= 1'b0;
                            state <= IDLE;
                            s_axis_tready <= 1'b1;
                            output_index <= 4'd0;
                            batch_completed <= 1'b1;
                            output_stall_detected <= 1'b0; // Reset stall detection
                            
                            if (DEBUG_ENABLE) begin
                                $display("\nBatch completed after flush:");
                                $display("  Transactions in this batch: %0d", batch_count);
                                $display("  Total transactions in batches: %0d", transactions_batched + 1);
                            end
                        end else begin
                            // Move to next transaction in batch
                            output_index <= output_index + 1;
                            state <= OUTPUT; // Return to normal output state
                            stall_counter <= 32'd0; // Reset stall counter
                        end
                    end else begin
                        // Still stalled, increment counter
                        stall_counter <= stall_counter + 1'b1;
                        
                        // If stalled for extremely long time, force reset
                        if (stall_counter >= BATCH_TIMEOUT_CYCLES * 4) begin
                            if (DEBUG_ENABLE) begin
                                $display("\nCRITICAL STALL - Forcing batch reset after %0d cycles", stall_counter);
                                $display("  Lost transaction at index %0d", output_index);
                            end
                            
                            // Force reset to IDLE state
                            state <= IDLE;
                            s_axis_tready <= 1'b1;
                            m_axis_tvalid <= 1'b0;
                            output_index <= 4'd0;
                            batch_completed <= 1'b1; // Signal batch completion to clear dependencies
                            output_stall_detected <= 1'b0;
                        end
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
