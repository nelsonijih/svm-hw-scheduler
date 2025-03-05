////////////
// Top-level module that instantiates all the stages pipeline and connect them together for the SVM Hardware Scheduler
////////////

module top #(
    parameter MAX_DEPENDENCIES = 1024, // Full dependency vector width
    parameter MAX_BATCH_SIZE = 8,
    parameter BATCH_TIMEOUT_CYCLES = 100,
    parameter MAX_PENDING_TRANSACTIONS = 16,
    parameter INSERTION_QUEUE_DEPTH = 8
) (
    input wire clk,
    input wire rst_n,
    
    // AXI-Stream input interface
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire [63:0] s_axis_tdata_owner_programID,
    input wire [1023:0] s_axis_tdata_read_dependencies,
    input wire [1023:0] s_axis_tdata_write_dependencies,
    
    // AXI-Stream output interface
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire [63:0] m_axis_tdata_owner_programID,
    output wire [1023:0] m_axis_tdata_read_dependencies,
    output wire [1023:0] m_axis_tdata_write_dependencies,
    
    // Performance monitoring
    output wire [31:0] raw_conflicts,
    output wire [31:0] waw_conflicts,
    output wire [31:0] war_conflicts,
    output wire [31:0] filter_hits,
    output wire [31:0] queue_occupancy,
    output wire [31:0] transactions_processed
);

    // Batch completion signal
    wire batch_completed;
    
    // Conflict checker to insertion connections
    wire conflict_checker_to_insertion_tvalid;
    wire conflict_checker_to_insertion_tready;
    wire [63:0] conflict_checker_to_insertion_tdata_owner_programID;
    wire [1023:0] conflict_checker_to_insertion_tdata_read_dependencies;
    wire [1023:0] conflict_checker_to_insertion_tdata_write_dependencies;
    
    // Insertion to batch connections
    wire insertion_to_batch_tvalid;
    wire insertion_to_batch_tready;
    wire [63:0] insertion_to_batch_tdata_owner_programID;
    wire [1023:0] insertion_to_batch_tdata_read_dependencies;
    wire [1023:0] insertion_to_batch_tdata_write_dependencies;
    
    // Instantiate enhanced conflict checker with filtering
    conflict_checker #(
        .MAX_DEPENDENCIES(MAX_DEPENDENCIES)
    ) conflict_checker_inst (
        .clk(clk),
        .rst_n(rst_n),
        
        // Input interface
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata_owner_programID(s_axis_tdata_owner_programID),
        .s_axis_tdata_read_dependencies(s_axis_tdata_read_dependencies),
        .s_axis_tdata_write_dependencies(s_axis_tdata_write_dependencies),
        
        // Output interface
        .m_axis_tvalid(conflict_checker_to_insertion_tvalid),
        .m_axis_tready(conflict_checker_to_insertion_tready),
        .m_axis_tdata_owner_programID(conflict_checker_to_insertion_tdata_owner_programID),
        .m_axis_tdata_read_dependencies(conflict_checker_to_insertion_tdata_read_dependencies),
        .m_axis_tdata_write_dependencies(conflict_checker_to_insertion_tdata_write_dependencies),
        
        // Batch control signals
        .batch_completed(batch_completed),
        
        // Performance monitoring
        .raw_conflicts(raw_conflicts),
        .waw_conflicts(waw_conflicts),
        .war_conflicts(war_conflicts),
        .filter_hits(filter_hits)
    );
    
    // Instantiate insertion stage
    insertion #(
        .MAX_PENDING_TRANSACTIONS(MAX_PENDING_TRANSACTIONS),
        .INSERTION_QUEUE_DEPTH(INSERTION_QUEUE_DEPTH)
    ) insertion_inst (
        .clk(clk),
        .rst_n(rst_n),
        
        // Input interface
        .s_axis_tvalid(conflict_checker_to_insertion_tvalid),
        .s_axis_tready(conflict_checker_to_insertion_tready),
        .s_axis_tdata_owner_programID(conflict_checker_to_insertion_tdata_owner_programID),
        .s_axis_tdata_read_dependencies(conflict_checker_to_insertion_tdata_read_dependencies),
        .s_axis_tdata_write_dependencies(conflict_checker_to_insertion_tdata_write_dependencies),
        
        // Output interface
        .m_axis_tvalid(insertion_to_batch_tvalid),
        .m_axis_tready(insertion_to_batch_tready),
        .m_axis_tdata_owner_programID(insertion_to_batch_tdata_owner_programID),
        .m_axis_tdata_read_dependencies(insertion_to_batch_tdata_read_dependencies),
        .m_axis_tdata_write_dependencies(insertion_to_batch_tdata_write_dependencies),
        
        // Performance monitoring
        .queue_occupancy(queue_occupancy)
    );
    
    // Instantiate batch stage
    batch #(
        .MAX_BATCH_SIZE(MAX_BATCH_SIZE),
        .BATCH_TIMEOUT_CYCLES(BATCH_TIMEOUT_CYCLES)
    ) batch_inst (
        .clk(clk),
        .rst_n(rst_n),
        
        // Input interface
        .s_axis_tvalid(insertion_to_batch_tvalid),
        .s_axis_tready(insertion_to_batch_tready),
        .s_axis_tdata_owner_programID(insertion_to_batch_tdata_owner_programID),
        .s_axis_tdata_read_dependencies(insertion_to_batch_tdata_read_dependencies),
        .s_axis_tdata_write_dependencies(insertion_to_batch_tdata_write_dependencies),
        
        // Output interface
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata_owner_programID(m_axis_tdata_owner_programID),
        .m_axis_tdata_read_dependencies(m_axis_tdata_read_dependencies),
        .m_axis_tdata_write_dependencies(m_axis_tdata_write_dependencies),
        
        // Batch completion signal
        .batch_completed(batch_completed),
        
        // Performance monitoring
        .transactions_processed(transactions_processed)
    );

endmodule
