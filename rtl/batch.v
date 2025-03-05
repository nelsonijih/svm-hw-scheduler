module batch #(
    parameter MAX_BATCH_SIZE = 8,
    parameter BATCH_TIMEOUT_CYCLES = 100
) (
    input wire clk,
    input wire rst_n,
    
    // AXI-Stream input interface
    input wire s_axis_tvalid,
    output reg s_axis_tready,
    input wire [63:0] s_axis_tdata_owner_programID,
    input wire [1023:0] s_axis_tdata_read_dependencies,
    input wire [1023:0] s_axis_tdata_write_dependencies,
    
    // AXI-Stream output interface
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg [63:0] m_axis_tdata_owner_programID,
    output reg [1023:0] m_axis_tdata_read_dependencies,
    output reg [1023:0] m_axis_tdata_write_dependencies,
    
    // Batch completion signal
    output reg batch_completed,
    
    // Performance monitoring
    output reg [31:0] transactions_processed
);

    // FSM states
    localparam IDLE = 2'b00;
    localparam COLLECT = 2'b01;
    localparam OUTPUT = 2'b10;
    reg [1:0] state;
    
    // Batch storage
    reg [63:0] batch_owner_programID [0:MAX_BATCH_SIZE-1];
    reg [1023:0] batch_read_deps [0:MAX_BATCH_SIZE-1];
    reg [1023:0] batch_write_deps [0:MAX_BATCH_SIZE-1];
    reg [3:0] batch_count;
    reg [3:0] output_index;
    
    // Timeout counter
    reg [31:0] timeout_counter;
    
    // Debug counter
    reg [31:0] debug_cycles;
    
    // Main control logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            s_axis_tready <= 1'b1;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata_owner_programID <= 64'd0;
            m_axis_tdata_read_dependencies <= 1024'd0;
            m_axis_tdata_write_dependencies <= 1024'd0;
            
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
                    
                    // Accept new transactions until batch is full or timeout
                    s_axis_tready <= (batch_count < MAX_BATCH_SIZE);
                    
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Store transaction in batch
                        batch_owner_programID[batch_count] <= s_axis_tdata_owner_programID;
                        batch_read_deps[batch_count] <= s_axis_tdata_read_dependencies;
                        batch_write_deps[batch_count] <= s_axis_tdata_write_dependencies;
                        
                        batch_count <= batch_count + 1'b1;
                        timeout_counter <= 32'd0;
                        
                        // If batch is full, start outputting
                        if (batch_count == MAX_BATCH_SIZE - 1) begin
                            state <= OUTPUT;
                            output_index <= 4'd0;
                        end
                    end
                    else if (timeout_counter >= BATCH_TIMEOUT_CYCLES && batch_count > 0) begin
                        // Timeout reached with transactions in batch
                        state <= OUTPUT;
                        output_index <= 4'd0;
                    end
                end
                
                OUTPUT: begin
                    // Output transactions one by one
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata_owner_programID <= batch_owner_programID[output_index];
                    m_axis_tdata_read_dependencies <= batch_read_deps[output_index];
                    m_axis_tdata_write_dependencies <= batch_write_deps[output_index];
                    
                    if (m_axis_tready) begin
                        // Transaction accepted
                        transactions_processed <= transactions_processed + 1'b1;
                        
                        if (output_index == batch_count - 1) begin
                            // All transactions in batch have been output
                            m_axis_tvalid <= 1'b0;
                            state <= IDLE;
                            s_axis_tready <= 1'b1;
                            
                            // Signal batch completion
                            batch_completed <= 1'b1;
                            $display("Batch completed at time %0t - Signaling completion", $time);
                        end
                        else begin
                            // Move to next transaction in batch
                            output_index <= output_index + 1'b1;
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
