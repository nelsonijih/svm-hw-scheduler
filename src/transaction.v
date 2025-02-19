/////////
// Transaction module to represent a transaction.
/////////

`timescale 1ns / 1ps

module transaction#(
    parameter NUM_DEPENDENCIES = 1024, // the # of entries for each read and write dependenceies per transaction
    parameter ACCOUNT_WIDTH = 64 //account or program ID is 64-bit wide
)
 (
input wire clk,
input wire rst,
input wire [ACCOUNT_WIDTH-1:0] account_owner_or_program_id, //64-bit value
input wire [NUM_DEPENDENCIES-1:0][ACCOUNT_WIDTH-1:0] read_dependencies, //ACCOUNT_WIDTH-bit values x NUM_DEPENDENCIES
input wire [NUM_DEPENDENCIES-1:0][ACCOUNT_WIDTH-1:0] write_dependencies //ACCOUNT_WIDTH-bit values x NUM_DEPENDENCIES

);


//TODO: Implementation this is currently could be used for just debugging purposes.

endmodule