////////////
// Filter Engine - responsible for batch dependency tracking
////////////

module filter_engine #(
    parameter MAX_DEPENDENCIES = 1024
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
    
    // Batch dependency tracking
    input wire [MAX_DEPENDENCIES-1:0] batch_read_dependencies,
    input wire [MAX_DEPENDENCIES-1:0] batch_write_dependencies,
    
    // Performance monitoring
    output reg [31:0] filter_hits
);

    // Internal registers
    reg [63:0] owner_programID_r;
    reg [MAX_DEPENDENCIES-1:0] read_deps_r;
    reg [MAX_DEPENDENCIES-1:0] write_deps_r;
    
    // Conflict detection
    wire has_raw_conflict = |(read_deps_r & batch_write_dependencies);
    wire has_waw_conflict = |(write_deps_r & batch_write_dependencies);
    wire has_war_conflict = |(write_deps_r & batch_read_dependencies);
    wire has_conflict = has_raw_conflict || has_waw_conflict || has_war_conflict;
    
    // State machine states
    localparam IDLE = 2'b00;
    localparam FILTER = 2'b01;
    localparam OUTPUT = 2'b10;
    reg [1:0] state;
    
    // State machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            s_axis_tready <= 1'b0;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata_owner_programID <= 64'd0;
            m_axis_tdata_read_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            m_axis_tdata_write_dependencies <= {MAX_DEPENDENCIES{1'b0}};
            owner_programID_r <= 64'd0;
            read_deps_r <= {MAX_DEPENDENCIES{1'b0}};
            write_deps_r <= {MAX_DEPENDENCIES{1'b0}};
            filter_hits <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    s_axis_tready <= 1'b1;
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Latch input data
                        owner_programID_r <= s_axis_tdata_owner_programID;
                        read_deps_r <= s_axis_tdata_read_dependencies;
                        write_deps_r <= s_axis_tdata_write_dependencies;
                        s_axis_tready <= 1'b0;
                        state <= FILTER;
                    end
                end
                
                FILTER: begin
                    // Make filtering decision based on conflicts
                    if (has_conflict) begin
                        // Transaction has conflict, increment counter and discard
                        filter_hits <= filter_hits + 1'b1;
                        $display("Filter Engine: Transaction %h filtered due to conflict", owner_programID_r);
                        if (has_raw_conflict) $display("  - RAW conflict detected");
                        if (has_waw_conflict) $display("  - WAW conflict detected");
                        if (has_war_conflict) $display("  - WAR conflict detected");
                        state <= IDLE;
                        s_axis_tready <= 1'b1;
                    end else begin
                        // No conflict, forward transaction
                        m_axis_tdata_owner_programID <= owner_programID_r;
                        m_axis_tdata_read_dependencies <= read_deps_r;
                        m_axis_tdata_write_dependencies <= write_deps_r;
                        m_axis_tvalid <= 1'b1;
                        state <= OUTPUT;
                    end
                end
                
                OUTPUT: begin
                    // Wait for downstream to accept
                    if (m_axis_tvalid && m_axis_tready) begin
                        m_axis_tvalid <= 1'b0;
                        state <= IDLE;
                        s_axis_tready <= 1'b1;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule
