/////////
// Batch module
/////////

`timescale 1ns / 1ps

module batch #(
    parameter TX_PER_BATCH,    // max of 48 per batch
    parameter ACCOUNT_WIDTH
)(
    input wire clk,
    input wire rst,
    input wire [TX_PER_BATCH-1:0][ACCOUNT_WIDTH-1:0] account_owners,
    input wire new_tx, //this is when conflict_check has something to be added to the batch.
    input wire batch_full,
    input wire batch_busy,
    input wire [7:0] batch_id, //This is the batch ID for instances generated.
    // Outputs
    output reg batch_is_ready     // The batch is ready for processing
);

    // Internal signals for conflict checking between pairs of transactions
    wire [TX_PER_BATCH-1:0][TX_PER_BATCH-1:0] no_conflicts;
    
    //TODO: Implementation


endmodule