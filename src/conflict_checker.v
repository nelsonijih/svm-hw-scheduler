/////////
// Conflict checker module to check for conflicts between transactions.
/////////

`timescale 1ns / 1ps

module conflict_checker #(
    parameter NUM_DEPENDENCIES = 1024, // the # of entries for each read and write dependenceies per transaction
    parameter ACCOUNT_WIDTH = 64 //account or program ID is 64-bit wide
    parameter MAX_BATCHES = 256 // the # of batches in waiting.
)(

    //INPUT
    input wire clk,rst,
    input wire [ACCOUNT_WIDTH-1:0] account_owner_or_program_id, //64-bit value
    input wire [NUM_DEPENDENCIES-1:0][ACCOUNT_WIDTH-1:0] read_dependencies, //ACCOUNT_WIDTH-bit values x NUM_DEPENDENCIES
    input wire [NUM_DEPENDENCIES-1:0][ACCOUNT_WIDTH-1:0] write_dependencies //ACCOUNT_WIDTH-bit values x NUM_DEPENDENCIES
    input wire [7:0] batch_id //a batchID to check against. Lets assume 256 batches in waiting to be processed and forwarded to be executed.

    //OUTPUT
    output reg no_conflict, //indicates there is no conflict.
    output reg conflict_check_done //when the conflict checker completes.
);
    
    // TODO: Implementation. Given a transaction, check in current active batch if no conflict exists, then add, check another batch until no conflict exists


endmodule
