////////////
// Top-level module that instantiates all the stages pipeline and connect them together for the SVM Hardware Scheduler
////////////

module batcher #(
    parameter MAX_DEPENDENCIES = 256, // Full dependency vector width
    parameter MAX_BATCH_SIZE = 8,
    parameter BATCH_TIMEOUT_CYCLES = 100,
    parameter MAX_PENDING_TRANSACTIONS = 16,
    parameter INSERTION_QUEUE_DEPTH = 8,
    parameter INSTANCE_ID = 0      // Instance ID for debug output
) (
    input wire clk,
    input wire rst_n,
    
    // AXI-Stream input interface
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire [63:0] s_axis_tdata_owner_programID,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_read_dependencies,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_write_dependencies,
    
    // AXI-Stream output interface
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire [63:0] m_axis_tdata_owner_programID,
    output wire [MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies,
    output wire [MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies,
    
    // Performance monitoring
    output wire [31:0] raw_conflicts,
    output wire [31:0] waw_conflicts,
    output wire [31:0] war_conflicts,
    output wire [31:0] filter_hits,
    output wire [31:0] queue_occupancy,
    output wire [31:0] transactions_processed,  // From conflict checker - tracks total valid transactions
    output wire [31:0] transactions_batched,   // From batch module - tracks transactions in completed batches
    output wire [31:0] batch_stall_count,      // From batch module - counts stalls in batch stage
    output wire [31:0] current_batch_size,     // From batch module - current number of transactions in batch
    output wire [31:0] transactions_in_queue,  // From insertion module - tracks transactions in queue
    output wire [31:0] transactions_in_batch,  // From batch module - tracks transactions in current batch
    output wire batch_completed,               // Indicates when a batch has completed
    
    // Global dependency tracking interface
    output wire new_batch_valid,              // Signal to register new batch with global manager
    output wire [MAX_DEPENDENCIES-1:0] batch_read_deps_union,  // Union of read dependencies in batch
    output wire [MAX_DEPENDENCIES-1:0] batch_write_deps_union, // Union of write dependencies in batch
    output wire [63:0] batch_owner_id        // Owner ID for the batch (for temporal conflict detection)
);

    // Transaction accepted signal
    wire transaction_accepted;
    
    // Insertion to batch connections
    wire insertion_to_batch_tvalid;
    wire insertion_to_batch_tready;
    wire [63:0] insertion_to_batch_tdata_owner_programID;
    wire [MAX_DEPENDENCIES-1:0] insertion_to_batch_tdata_read_dependencies;
    wire [MAX_DEPENDENCIES-1:0] insertion_to_batch_tdata_write_dependencies;
    
    // Note: conflict_checker stage has been removed
    // Input now connects directly to insertion stage
    
    // Instantiate insertion stage
    insertion #(
        .MAX_PENDING_TRANSACTIONS(MAX_PENDING_TRANSACTIONS),
        .INSERTION_QUEUE_DEPTH(INSERTION_QUEUE_DEPTH)
    ) insertion_inst (
        .clk(clk),
        .rst_n(rst_n),
        
        // Input interface connected directly to module inputs
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata_owner_programID(s_axis_tdata_owner_programID),
        .s_axis_tdata_read_dependencies(s_axis_tdata_read_dependencies),
        .s_axis_tdata_write_dependencies(s_axis_tdata_write_dependencies),
        
        // Output interface
        .m_axis_tvalid(insertion_to_batch_tvalid),
        .m_axis_tready(insertion_to_batch_tready),
        .m_axis_tdata_owner_programID(insertion_to_batch_tdata_owner_programID),
        .m_axis_tdata_read_dependencies(insertion_to_batch_tdata_read_dependencies),
        .m_axis_tdata_write_dependencies(insertion_to_batch_tdata_write_dependencies),
        
        // Batch control signals
        .batch_completed(batch_completed),
        
        // Global dependency tracking
        .batch_read_deps_union(batch_read_deps_union),
        .batch_write_deps_union(batch_write_deps_union),
        .batch_owner_id(batch_owner_id),
        
        // Performance monitoring (moved from conflict_checker)
        .raw_conflicts(raw_conflicts),
        .waw_conflicts(waw_conflicts),
        .war_conflicts(war_conflicts),
        .filter_hits(filter_hits),
        .transactions_processed(transactions_processed),
        
        // Original performance monitoring
        .queue_occupancy(queue_occupancy),
        .transactions_in_queue(transactions_in_queue)
    );
    
    // Instantiate batch stage
    batch #(
        .MAX_BATCH_SIZE(MAX_BATCH_SIZE),
        .BATCH_TIMEOUT_CYCLES(BATCH_TIMEOUT_CYCLES),
        .INSTANCE_ID(INSTANCE_ID)
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
        
        // Global dependency tracking
        .new_batch_valid(new_batch_valid),
        .batch_read_deps_union(batch_read_deps_union),
        .batch_write_deps_union(batch_write_deps_union),
        
        // Performance monitoring
        .transactions_batched(transactions_batched),
        .transaction_accepted(transaction_accepted),
        .batch_stall_count(batch_stall_count),
        .current_batch_size(current_batch_size),
        .transactions_in_batch(transactions_in_batch)
    );

endmodule
