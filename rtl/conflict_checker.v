module conflict_checker #(
    parameter MAX_DEPENDENCIES = 1024,
    parameter CHUNK_SIZE = 64,
    parameter NUM_PARALLEL_CHECKS = 16
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
    
    // Batch control signals
    input wire batch_completed,
    
    // Performance monitoring
    output reg [31:0] raw_conflicts,
    output reg [31:0] waw_conflicts,
    output reg [31:0] war_conflicts,
    output reg [31:0] filter_hits
);

    // Internal batch dependency tracking
    reg [1023:0] batch_read_dependencies;
    reg [1023:0] batch_write_dependencies;

    // FSM states
    localparam IDLE = 2'b00;
    localparam CHECK = 2'b01;
    localparam OUTPUT = 2'b10;
    reg [1:0] state;
    
    // Conflict detection results
    reg has_raw_conflict;
    reg has_waw_conflict;
    reg has_war_conflict;
    reg has_any_conflict;
    
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
            
            has_raw_conflict <= 1'b0;
            has_waw_conflict <= 1'b0;
            has_war_conflict <= 1'b0;
            has_any_conflict <= 1'b0;
            
            raw_conflicts <= 32'd0;
            waw_conflicts <= 32'd0;
            war_conflicts <= 32'd0;
            filter_hits <= 32'd0;
            
            debug_cycles <= 32'd0;
            
            // Initialize batch dependency tracking
            batch_read_dependencies <= 1024'd0;
            batch_write_dependencies <= 1024'd0;
        end
        else begin
            // Increment debug counter
            debug_cycles <= debug_cycles + 1'b1;
            
            // Default assignments
            s_axis_tready <= 1'b0;
            m_axis_tvalid <= 1'b0; // Default to not valid
            
            // Handle batch completion signal
            if (batch_completed) begin
                // Reset batch dependencies when batch is completed
                batch_read_dependencies <= 1024'd0;
                batch_write_dependencies <= 1024'd0;
                $display("Conflict Checker: Batch completed at time %0t - Reset batch dependencies", $time);
            end
            
            case (state)
                IDLE: begin
                    // Ready to accept new transaction
                    s_axis_tready <= 1'b1;
                    
                    // Reset conflict flags
                    has_raw_conflict <= 1'b0;
                    has_waw_conflict <= 1'b0;
                    has_war_conflict <= 1'b0;
                    has_any_conflict <= 1'b0;
                    
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Store transaction data
                        m_axis_tdata_owner_programID <= s_axis_tdata_owner_programID;
                        m_axis_tdata_read_dependencies <= s_axis_tdata_read_dependencies;
                        m_axis_tdata_write_dependencies <= s_axis_tdata_write_dependencies;
                        
                        // Move to check state
                        state <= CHECK;
                    end
                end
                
                CHECK: begin
                    // Check for RAW conflicts (Read-After-Write)
                    // New transaction reads, existing batch writes
                    if ((m_axis_tdata_read_dependencies & batch_write_dependencies) != 0) begin
                        has_raw_conflict <= 1'b1;
                    end
                    else begin
                        has_raw_conflict <= 1'b0;
                    end
                    
                    // Check for WAW conflicts (Write-After-Write)
                    // New transaction writes, existing batch writes
                    if ((m_axis_tdata_write_dependencies & batch_write_dependencies) != 0) begin
                        has_waw_conflict <= 1'b1;
                    end
                    else begin
                        has_waw_conflict <= 1'b0;
                    end
                    
                    // Check for WAR conflicts (Write-After-Read)
                    // New transaction writes, existing batch reads
                    if ((m_axis_tdata_write_dependencies & batch_read_dependencies) != 0) begin
                        has_war_conflict <= 1'b1;
                    end
                    else begin
                        has_war_conflict <= 1'b0;
                    end
                    
                    // Move to output state
                    state <= OUTPUT;
                end
                
                OUTPUT: begin
                    // Determine if any conflict exists
                    has_any_conflict <= has_raw_conflict || has_waw_conflict || has_war_conflict;
                    
                    // Update performance counters
                    if (has_raw_conflict) begin
                        raw_conflicts <= raw_conflicts + 1'b1;
                        $display("RAW conflict detected at time %0t", $time);
                    end
                    
                    if (has_waw_conflict) begin
                        waw_conflicts <= waw_conflicts + 1'b1;
                        $display("WAW conflict detected at time %0t", $time);
                    end
                    
                    if (has_war_conflict) begin
                        war_conflicts <= war_conflicts + 1'b1;
                        $display("WAR conflict detected at time %0t", $time);
                    end
                    
                    if (has_raw_conflict || has_waw_conflict || has_war_conflict) begin
                        // Transaction has conflicts, filter it out
                        filter_hits <= filter_hits + 1'b1;
                        $display("Transaction filtered due to conflicts at time %0t", $time);
                        
                        // Return to IDLE without forwarding
                        state <= IDLE;
                        s_axis_tready <= 1'b1;
                    end
                    else begin
                        // No conflicts, forward transaction
                        m_axis_tvalid <= 1'b1;
                        
                        if (m_axis_tready) begin
                            // Transaction accepted, update batch dependencies
                            batch_read_dependencies <= batch_read_dependencies | m_axis_tdata_read_dependencies;
                            batch_write_dependencies <= batch_write_dependencies | m_axis_tdata_write_dependencies;
                            
                            $display("Batch dependencies updated at time %0t", $time);
                            $display("  Read deps: %h", batch_read_dependencies | m_axis_tdata_read_dependencies);
                            $display("  Write deps: %h", batch_write_dependencies | m_axis_tdata_write_dependencies);
                            
                            // Return to IDLE
                            state <= IDLE;
                            s_axis_tready <= 1'b1;
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
