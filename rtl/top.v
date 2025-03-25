module top #(
    parameter NUM_PARALLEL_INSTANCES = 4,
    parameter MAX_DEPENDENCIES = 256,
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
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_read_dependencies,
    input wire [MAX_DEPENDENCIES-1:0] s_axis_tdata_write_dependencies,
    
    // AXI-Stream output interface (one per instance)
    output wire [NUM_PARALLEL_INSTANCES-1:0] m_axis_tvalid,
    input wire [NUM_PARALLEL_INSTANCES-1:0] m_axis_tready,
    output wire [NUM_PARALLEL_INSTANCES-1:0][63:0] m_axis_tdata_owner_programID,
    output wire [NUM_PARALLEL_INSTANCES-1:0][MAX_DEPENDENCIES-1:0] m_axis_tdata_read_dependencies,
    output wire [NUM_PARALLEL_INSTANCES-1:0][MAX_DEPENDENCIES-1:0] m_axis_tdata_write_dependencies,
    
    // Aggregated performance monitoring
    output reg [31:0] total_raw_conflicts,
    output reg [31:0] total_waw_conflicts,
    output reg [31:0] total_war_conflicts,
    output reg [31:0] total_filter_hits,
    output reg [31:0] total_queue_occupancy,
    output reg [31:0] total_transactions_processed,
    output reg [31:0] total_transactions_batched,
    output wire [NUM_PARALLEL_INSTANCES-1:0] batch_completed
);

    // Round-robin instance selection
    reg [$clog2(NUM_PARALLEL_INSTANCES)-1:0] current_instance;
    
    // Per-instance signals
    wire [NUM_PARALLEL_INSTANCES-1:0] instance_tready;
    wire [31:0] instance_raw_conflicts [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_waw_conflicts [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_war_conflicts [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_filter_hits [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_queue_occupancy [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_transactions_processed [NUM_PARALLEL_INSTANCES-1:0];
    wire [31:0] instance_transactions_batched [NUM_PARALLEL_INSTANCES-1:0];
    
    // Input demux signals
    reg [NUM_PARALLEL_INSTANCES-1:0] instance_tvalid;
    
    // Round-robin instance selection logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_instance <= 0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            // Move to next instance when transaction is accepted
            current_instance <= current_instance + 1;
            if (current_instance == NUM_PARALLEL_INSTANCES - 1)
                current_instance <= 0;
        end
    end
    
    // Input demux logic
    always @(*) begin
        instance_tvalid = 0;
        if (s_axis_tvalid)
            instance_tvalid[current_instance] = 1'b1;
    end
    
    // Connect input ready signal
    assign s_axis_tready = instance_tready[current_instance];
    
    // Instantiate multiple conflict_detection modules
    genvar i;
    generate
        for (i = 0; i < NUM_PARALLEL_INSTANCES; i = i + 1) begin : cd_inst
            conflict_detection #(
                .MAX_DEPENDENCIES(MAX_DEPENDENCIES),
                .MAX_BATCH_SIZE(MAX_BATCH_SIZE),
                .BATCH_TIMEOUT_CYCLES(BATCH_TIMEOUT_CYCLES),
                .MAX_PENDING_TRANSACTIONS(MAX_PENDING_TRANSACTIONS),
                .INSERTION_QUEUE_DEPTH(INSERTION_QUEUE_DEPTH)
            ) cd_inst (
                .clk(clk),
                .rst_n(rst_n),
                
                // Input interface
                .s_axis_tvalid(instance_tvalid[i]),
                .s_axis_tready(instance_tready[i]),
                .s_axis_tdata_owner_programID(s_axis_tdata_owner_programID),
                .s_axis_tdata_read_dependencies(s_axis_tdata_read_dependencies),
                .s_axis_tdata_write_dependencies(s_axis_tdata_write_dependencies),
                
                // Output interface
                .m_axis_tvalid(m_axis_tvalid[i]),
                .m_axis_tready(m_axis_tready[i]),
                .m_axis_tdata_owner_programID(m_axis_tdata_owner_programID[i]),
                .m_axis_tdata_read_dependencies(m_axis_tdata_read_dependencies[i]),
                .m_axis_tdata_write_dependencies(m_axis_tdata_write_dependencies[i]),
                
                // Performance monitoring
                .raw_conflicts(instance_raw_conflicts[i]),
                .waw_conflicts(instance_waw_conflicts[i]),
                .war_conflicts(instance_war_conflicts[i]),
                .filter_hits(instance_filter_hits[i]),
                .queue_occupancy(instance_queue_occupancy[i]),
                .transactions_processed(instance_transactions_processed[i]),
                .transactions_batched(instance_transactions_batched[i]),
                .batch_completed(batch_completed[i])
            );
        end
    endgenerate
    
    // Aggregate performance counters
    integer j;
    always @(*) begin
        total_raw_conflicts = 0;
        total_waw_conflicts = 0;
        total_war_conflicts = 0;
        total_filter_hits = 0;
        total_queue_occupancy = 0;
        total_transactions_processed = 0;
        total_transactions_batched = 0;
        
        for (j = 0; j < NUM_PARALLEL_INSTANCES; j = j + 1) begin
            total_raw_conflicts = total_raw_conflicts + instance_raw_conflicts[j];
            total_waw_conflicts = total_waw_conflicts + instance_waw_conflicts[j];
            total_war_conflicts = total_war_conflicts + instance_war_conflicts[j];
            total_filter_hits = total_filter_hits + instance_filter_hits[j];
            total_queue_occupancy = total_queue_occupancy + instance_queue_occupancy[j];
            total_transactions_processed = total_transactions_processed + instance_transactions_processed[j];
            total_transactions_batched = total_transactions_batched + instance_transactions_batched[j];
        end
    end

endmodule
