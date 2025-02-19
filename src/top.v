/////////
// Top module for the scheduler system
/////////

`timescale 1ns / 1ps

module top #(
    parameter TX_PER_BATCH = 48,    // Maximum number of transactions in a batch
    parameter NUM_DEPENDENCIES = 1024, // Dependency list entries
    parameter ACCOUNT_WIDTH = 64      // Account/program ID width in bits.
)(
    input wire clk,
    input wire rst,
    
    // Transaction input interface
    input wire [ACCOUNT_WIDTH-1:0] tx_owner, // Account owners or program IDs
    input wire [NUM_DEPENDENCIES-1:0][ACCOUNT_WIDTH-1:0] tx_read_deps,  // Read dependencies
    input wire [NUM_DEPENDENCIES-1:0][ACCOUNT_WIDTH-1:0] tx_write_deps, // Write dependencies
    
    // Output interface
    output wire [TX_PER_BATCH-1:0] tx_can_execute, // Which transactions can execute
    output wire batch_is_ready                     // The batch is ready for processing
);

  
    reg [7:0] batch_id;   // batch ID for all instances generated.

    // transaction instance for reading in tx from buffer stream.
    transaction #(
                .NUM_DEPENDENCIES(NUM_DEPENDENCIES),
                .ACCOUNT_WIDTH(ACCOUNT_WIDTH)
         ) transaction_inst (
                .clk(clk),
                .rst(rst),
                .account_owner_or_program_id(tx_owner),
                .read_dependencies(tx_read_deps),
                .write_dependencies(tx_write_deps)
            );

    // instantiate conflict checker module to check for conflicts between this current tx and the other txs in the batch.
    //TODO: Instantiate multiple conflict checker modules to work on multiple txs.
    conflict_checker #(
        .NUM_DEPENDENCIES(NUM_DEPENDENCIES),
        .ACCOUNT_WIDTH(ACCOUNT_WIDTH)
    ) conflict_checker_inst (
        .clk(clk),
        .rst(rst),
        .account_owner_or_program_id(tx_owner),
        .read_dependencies(tx_read_deps),
        .write_dependencies(tx_write_deps),
        .no_conflict(no_conflict_detected),
        .conflict_check_done(conflict_check_done),
        .batch_id(batch_id)
    );

    // Instantiate 256 batches. Each batch is a 48 transaction batch for storing tx account owners for the batch.
    batch #(
        .TX_PER_BATCH(TX_PER_BATCH),
        .ACCOUNT_WIDTH(ACCOUNT_WIDTH)
    ) batch_inst [255:0](
        .clk(clk),
        .rst(rst),
        .account_owners(tx_owner),
        .new_tx(~new_batch_needed && conflict_check_done), // Only add to current batch if no conflict
        .batch_full(batch_full),
        .batch_busy(batch_busy),
        .batch_id(batch_id)
    );


endmodule