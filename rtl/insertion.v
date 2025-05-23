////////////
// Enhanced insertion module that includes dependency tracking
// Now directly connected to input and handles dependency accumulation
////////////

module insertion #(
    parameter MAX_DEPENDENCIES = 256,
    parameter MAX_PENDING_TRANSACTIONS = 16,
    parameter INSERTION_QUEUE_DEPTH = 32  // Increased queue depth
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
    
    // Batch control
    input wire batch_completed,
    
    // Global dependency tracking
    output reg [MAX_DEPENDENCIES-1:0] batch_read_deps_union,
    output reg [MAX_DEPENDENCIES-1:0] batch_write_deps_union,
    output reg [63:0] batch_owner_id,  // Owner ID for batch (for temporal conflict detection)
    
    // Performance monitoring (from conflict_checker)
    output reg [31:0] raw_conflicts,
    output reg [31:0] waw_conflicts,
    output reg [31:0] war_conflicts,
    output reg [31:0] filter_hits,
    output reg [31:0] transactions_processed,
    
    // Original performance monitoring
    output reg [31:0] queue_occupancy,
    output reg [31:0] transactions_in_queue
);

    // FSM states
    localparam IDLE = 2'b00;
    localparam OUTPUT = 2'b01;
    localparam WAIT_ACCEPT = 2'b10;
    reg [1:0] state;
    
    // Batch dependency tracking (moved from conflict_checker)
    reg [MAX_DEPENDENCIES-1:0] batch_read_dependencies;
    reg [MAX_DEPENDENCIES-1:0] batch_write_dependencies;
    
    // Queue storage
    reg [63:0] owner_programID_queue [0:INSERTION_QUEUE_DEPTH-1];
    reg [MAX_DEPENDENCIES-1:0] read_dependencies_queue [0:INSERTION_QUEUE_DEPTH-1];
    reg [MAX_DEPENDENCIES-1:0] write_dependencies_queue [0:INSERTION_QUEUE_DEPTH-1];
    reg [5:0] queue_head;  // Increased to 6 bits for larger queue
    reg [5:0] queue_tail;  // Increased to 6 bits for larger queue
    reg queue_empty;
    reg queue_full;
    
    // Track if current output transaction is from queue
    reg current_from_queue;
    
    // Debug counter and transaction tracking
    reg [31:0] debug_cycles;
    reg [31:0] transactions_in_flight;
    
    // Queue management functions
    wire [5:0] next_tail = (queue_tail == INSERTION_QUEUE_DEPTH-1) ? 6'd0 : queue_tail + 6'd1;
    wire [5:0] next_head = (queue_head == INSERTION_QUEUE_DEPTH-1) ? 6'd0 : queue_head + 6'd1;
    
    // Main control logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            s_axis_tready <= 1'b1;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata_owner_programID <= 64'd0;
            m_axis_tdata_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            m_axis_tdata_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            
            // Batch dependency tracking reset
            batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            batch_read_deps_union <= {MAX_DEPENDENCIES{1'b0}};
            batch_write_deps_union <= {MAX_DEPENDENCIES{1'b0}};
            batch_owner_id <= 64'd0;  // Initialize batch owner ID
            
            // Performance counters reset
            raw_conflicts <= 32'd0;
            waw_conflicts <= 32'd0;
            war_conflicts <= 32'd0;
            filter_hits <= 32'd0;
            transactions_processed <= 32'd0;
            
            queue_head <= 6'd0;
            queue_tail <= 6'd0;
            queue_empty <= 1'b1;
            queue_full <= 1'b0;
            queue_occupancy <= 32'd0;
            current_from_queue <= 1'b0;
            debug_cycles <= 32'd0;
            transactions_in_flight <= 32'd0;
            transactions_in_queue <= 32'd0;
        end
        else begin
            // Increment debug counter
            debug_cycles <= debug_cycles + 1'b1;
            
            // Update dependency unions for global manager
            batch_read_deps_union <= batch_read_dependencies;
            batch_write_deps_union <= batch_write_dependencies;
            
            // Update batch owner ID - use the owner ID of the first transaction in the batch
            // This helps with temporal conflict detection
            if (queue_empty && s_axis_tvalid && s_axis_tready) begin
                // First transaction in a new batch
                batch_owner_id <= s_axis_tdata_owner_programID;
            end
            
            // Handle batch completion
            if (batch_completed) begin
                // Clear all batch dependencies
                batch_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
                batch_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            end
            
            case (state)
                IDLE: begin
                    // Default: ready for input if queue not full
                    s_axis_tready <= !queue_full;
                    m_axis_tvalid <= 1'b0;
                    
                    if (!queue_empty) begin
                        // Process from queue
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata_owner_programID <= owner_programID_queue[queue_head];
                        m_axis_tdata_read_dependencies <= read_dependencies_queue[queue_head];
                        m_axis_tdata_write_dependencies <= write_dependencies_queue[queue_head];
                        current_from_queue <= 1'b1;
                        state <= OUTPUT;
                        transactions_in_queue <= transactions_in_queue + 1'b1;
                    end
                    else if (s_axis_tvalid && !queue_full) begin
                        // Directly forward if queue empty
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata_owner_programID <= s_axis_tdata_owner_programID;
                        m_axis_tdata_read_dependencies <= s_axis_tdata_read_dependencies;
                        m_axis_tdata_write_dependencies <= s_axis_tdata_write_dependencies;
                        current_from_queue <= 1'b0;
                        state <= OUTPUT;
                        
                        // Update dependency tracking
                        batch_read_dependencies <= batch_read_dependencies | s_axis_tdata_read_dependencies;
                        batch_write_dependencies <= batch_write_dependencies | s_axis_tdata_write_dependencies;
                        
                        // Update transactions processed counter
                        transactions_processed <= transactions_processed + 1;
                        transactions_in_queue <= transactions_in_queue + 1'b1;
                    end
                end
                
                OUTPUT: begin
                    // Hold current transaction until accepted
                    m_axis_tvalid <= 1'b1;
                    s_axis_tready <= 1'b0; // Don't accept new transactions while outputting
                    
                    if (m_axis_tready) begin
                        if (current_from_queue) begin
                            // Update queue if current transaction was from queue
                            queue_head <= next_head;
                            queue_empty <= (next_head == queue_tail);
                            queue_full <= 1'b0;
                            queue_occupancy <= queue_occupancy - 1'b1;
                        end
                        
                        transactions_in_queue <= transactions_in_queue - 1'b1;
                        state <= WAIT_ACCEPT;
                    end
                end
                
                WAIT_ACCEPT: begin
                    // Clear valid and prepare for next transaction
                    m_axis_tvalid <= 1'b0;
                    s_axis_tready <= !queue_full;
                    
                    if (s_axis_tvalid && !queue_full) begin
                        // Queue new transaction
                        owner_programID_queue[queue_tail] <= s_axis_tdata_owner_programID;
                        read_dependencies_queue[queue_tail] <= s_axis_tdata_read_dependencies;
                        write_dependencies_queue[queue_tail] <= s_axis_tdata_write_dependencies;
                        
                        // Update dependency tracking
                        batch_read_dependencies <= batch_read_dependencies | s_axis_tdata_read_dependencies;
                        batch_write_dependencies <= batch_write_dependencies | s_axis_tdata_write_dependencies;
                        
                        // Update transactions processed counter
                        transactions_processed <= transactions_processed + 1;
                        
                        queue_tail <= next_tail;
                        queue_empty <= 1'b0;
                        queue_full <= (next_tail == queue_head);
                        queue_occupancy <= queue_occupancy + 1'b1;
                    end
                    
                    state <= IDLE;
                end
                
                default: begin
                    state <= IDLE;
                    s_axis_tready <= !queue_full;
                end
            endcase
            
            // Safety timeout - if stuck for too long, reset state
            if (debug_cycles > 5000) begin  // Increased timeout
                state <= IDLE;
                s_axis_tready <= !queue_full;
                m_axis_tvalid <= 1'b0;
                debug_cycles <= 32'd0;
                transactions_in_flight <= queue_occupancy; // Reset to match queue
            end
        end
    end

endmodule
