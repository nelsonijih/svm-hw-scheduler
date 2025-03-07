module insertion #(
    parameter MAX_DEPENDENCIES = 256,
    parameter MAX_PENDING_TRANSACTIONS = 16,
    parameter INSERTION_QUEUE_DEPTH = 8
) (
    input wire clk,
    input wire rst_n,
    
    // AXI-Stream input interface
    input wire s_axis_tvalid,
    output reg s_axis_tready,
    input wire [63:0] s_axis_tdata_owner_programID,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_read_dependencies,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_write_dependencies,
    // has_conflict signal removed as conflict_checker now only forwards non-conflicting transactions
    
    // AXI-Stream output interface
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg [63:0] m_axis_tdata_owner_programID,
    output reg [MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies,
    output reg [MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies,
    
    // Performance monitoring
    output reg [31:0] queue_occupancy
);

    // FSM states
    localparam IDLE = 2'b00;
    localparam PROCESS = 2'b01;
    localparam OUTPUT = 2'b10;
    reg [1:0] state;
    
    // Queue storage
    reg [63:0] owner_programID_queue [0:INSERTION_QUEUE_DEPTH-1];
    reg [MAX_DEPENDENCIES-1:0] read_dependencies_queue [0:INSERTION_QUEUE_DEPTH-1];
    reg [MAX_DEPENDENCIES-1:0] write_dependencies_queue [0:INSERTION_QUEUE_DEPTH-1];
    // has_conflict_queue removed as conflict_checker now only forwards non-conflicting transactions
    reg [3:0] queue_head;
    reg [3:0] queue_tail;
    reg queue_empty;
    reg queue_full;
    
    // Debug counter
    reg [31:0] debug_cycles;
    
    // Queue management functions
    wire [3:0] next_tail = (queue_tail == INSERTION_QUEUE_DEPTH-1) ? 4'd0 : queue_tail + 4'd1;
    wire [3:0] next_head = (queue_head == INSERTION_QUEUE_DEPTH-1) ? 4'd0 : queue_head + 4'd1;
    
    // Main control logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            s_axis_tready <= 1'b1;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata_owner_programID <= 64'd0;
            m_axis_tdata_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            m_axis_tdata_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            
            queue_head <= 4'd0;
            queue_tail <= 4'd0;
            queue_empty <= 1'b1;
            queue_full <= 1'b0;
            queue_occupancy <= 32'd0;
            debug_cycles <= 32'd0;
        end
        else begin
            // Increment debug counter
            debug_cycles <= debug_cycles + 1'b1;
            
            // Default assignments
            s_axis_tready <= 1'b0;
            
            case (state)
                IDLE: begin
                    if (!queue_empty) begin
                        // Process from queue
                        m_axis_tvalid <= 1'b1;
                        m_axis_tdata_owner_programID <= owner_programID_queue[queue_head];
                        m_axis_tdata_read_dependencies <= read_dependencies_queue[queue_head];
                        m_axis_tdata_write_dependencies <= write_dependencies_queue[queue_head];
                        state <= OUTPUT;
                    end
                    else begin
                        // Ready for new input if queue not full
                        s_axis_tready <= !queue_full;
                        
                        if (s_axis_tvalid && s_axis_tready) begin
                            // Directly forward if queue empty
                            m_axis_tvalid <= 1'b1;
                            m_axis_tdata_owner_programID <= s_axis_tdata_owner_programID;
                            m_axis_tdata_read_dependencies <= s_axis_tdata_read_dependencies;
                            m_axis_tdata_write_dependencies <= s_axis_tdata_write_dependencies;
                            state <= OUTPUT;
                        end
                    end
                end
                
                OUTPUT: begin
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 1'b0;
                        
                        if (!queue_empty) begin
                            // Update queue head if we processed from queue
                            queue_head <= next_head;
                            queue_empty <= (next_head == queue_tail);
                            queue_full <= 1'b0;
                            queue_occupancy <= queue_occupancy - 1'b1;
                        end
                        
                        state <= IDLE;
                        s_axis_tready <= !queue_full;
                    end
                    else if (s_axis_tvalid && !queue_full) begin
                        // Store incoming transaction in queue while waiting
                        owner_programID_queue[queue_tail] <= s_axis_tdata_owner_programID;
                        read_dependencies_queue[queue_tail] <= s_axis_tdata_read_dependencies;
                        write_dependencies_queue[queue_tail] <= s_axis_tdata_write_dependencies;
                        // has_conflict_queue entry removed
                        
                        queue_tail <= next_tail;
                        queue_empty <= 1'b0;
                        queue_full <= (next_tail == queue_head);
                        queue_occupancy <= queue_occupancy + 1'b1;
                        
                        // Accept the transaction
                        s_axis_tready <= 1'b1;
                    end
                end
                
                default: begin
                    state <= IDLE;
                    s_axis_tready <= !queue_full;
                end
            endcase
            
            // Safety timeout - if stuck for too long, reset state
            if (debug_cycles > 1000) begin
                state <= IDLE;
                s_axis_tready <= !queue_full;
                m_axis_tvalid <= 1'b0;
                debug_cycles <= 32'd0;
            end
        end
    end

endmodule
