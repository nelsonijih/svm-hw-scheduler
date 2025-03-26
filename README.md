# SVM Transaction Scheduler High-level Design Specs
A 3-stage pipeline for reading SVM transactions and creating batches that contain non-conflicting transactions. 

<img width="1094" alt="pipelined-design" src="https://github.com/user-attachments/assets/4132d790-416a-4385-9f5b-5b5be61ac6fc" />

## Project structure
svm-hw-scheduler/
- Makefile           # For building the project and running tests.
- rtl/               # Verilog source files
- tb/                # test bench with testcases.
- sim/               # to place output from simulations
- src                # Old source. Ignore this folder in this branch

## Firedancer Solana microblock/parallel execution scheduling.
High-level idea: Accelerate conflict detection from the `fd_pack_schedule_impl` function in the diagram to an FPGA
<img width="1130" alt="Screenshot 2025-03-20 at 2 15 18 PM" src="https://github.com/user-attachments/assets/d7fe4b58-d48d-4e95-a1c0-a7530cf7c2df" />


## Design Implementation Overview & Components
- *rtl/top.v* -  Top level responsible for specifying the number of conflict_detection isntances we want, and forwarding the transactions to the conflict_detection instances in round-robin fashion.
- *rtl/conflict_detection.v* - An instance of all 3-stages of conflict detection wired together.
- *rtl/conflict_checker.v* - Responsible for checking conflicts between transactions and the current batch
- *rtl/insertion.v* - Responsible for signaling to the batch to accept transaction from the filter_engine
- *rtl/batch.v* - Responsible for adding a deconflicted transaction from the filter engine into the batch. 
- *tb/tb_svm_scheduler.v/* - Test cases with transactions that conflict and do not.

## Prerequisite
- Install verilog simulator(e.g icarius) and Wave form viewer(e.g gtkwave)
- Clone the repo
- cd to svm-hw-schduler
- type `make sim`to run simulation
- type `make wave` to view the simulation in waveform

## Tests
The test bench contains several transactions tests that conflict and some that do not
conflict. 

Blow is simulation sample output
<img width="1438" alt="svm-schduler-sim" src="https://github.com/user-attachments/assets/190b9e65-7967-43a9-8890-91d06e5bdaa5" />


- Transactions 1 & 2 conflicts when attemptign to add 2 after 1 was added, so 2 will not be added to the batch
- Transactions 3 & 4 conflicts when attempting to add 4 after 3 was added, so 4 will not be added to the batch
- Transactions 5 & 6 conflicts when attempting to add 6 after 5 was added, so 6 will not be added to the batch
- Transactions 7 & 8 do not conflict and will be added
- Transactions 9 & 10 conflicts when attempting to add 10 after 9 was added, so 10 will not be added.

### Assumptions
- Each transaction has max of 1024 read and write dependencies account list.


## Detailed RTL Implementation

### Key Features
- Configurable prefetch buffer depth
- Full dependency vector processing (1024 bits)
- AXI-Stream interface for efficient data transfer
- Performance monitoring counters

### Parameters
- `CHUNK_SIZE`: Size of dependency vectors (1024 bits)
- `PREFETCH_DEPTH`: Number of transactions to prefetch (default: 2)

### Interfaces
1. AXI-Stream Input
   - `s_axis_tvalid`: Input data valid signal
   - `s_axis_tready`: Ready to accept input
   - `s_axis_tdata_*`: Transaction data signals

2. Feedback Signals
   - `pipeline_ready`: Downstream ready signal
   - `accepted_id`: ID of accepted transaction
   - `has_conflict`: Conflict detection flag
   - `conflicting_id`: ID of conflicting transaction

3. Performance Monitoring
   - `transactions_processed`: Counter for processed transactions
   - `conflicts_detected`: Counter for detected conflicts
   - `raw_conflicts`: Counter for RAW conflicts
   - `waw_conflicts`: Counter for WAW conflicts
   - `war_conflicts`: Counter for WAR conflicts


## Performance Optimization

### 1. Memory Access
- Dual-port Block RAM usage
- Prefetch buffer to hide latency
- Full dependency vector processing

### 2. Conflict Detection
- Single-stage comprehensive conflict checking
- Optimized for hardware efficiency
- Detailed conflict type reporting

### 3. Pipeline Efficiency
- Prefetch buffer
- Streamlined processing
- AXI-Stream interface

## Testing

### TODO - Additional Testbenches
1. module/stage specific testbenches.

## TODO: Performance Monitoring
The design includes several performance counters:


## Future Improvements

 **Performance Optimization**
  - Using of Bloom filters to quickly reject obvious conflicts and fast conflict detection
  - Using of CAM for fast actual conflict detection.


- **Memory Efficiency**
  - Create a Tx read/write dependencies as a hashmap function that maps to an index of 1024 array(assuming no colossion) e.g 64-bit addr maps to just setting a single bit at a hashmap location. 
   For examples. A tx has the the following
   read_dep = [addr1, adddr2, ...] ...transformed and inserted into batch_read_deps[hashmap(read_dep[addr1])] = 1, etc
   write_dep = [addr1, adddr2, ...]...transformed and inserted into batch_write_deps[hashmap(write_dep[addr1])] = 1, etc. FPGA computes and sends back
  - Add bloom filter pre-screening to quickly reject obvious conflicts
  - Optimize storage for batch transactions using BRAM,etc

-  **Testbench Improvements**
  - Add randomized transaction generator with configurable conflict rates
  - Implement comprehensive coverage metrics for conflict scenarios

- **Integration Features**
  - Add debug and telemetry interfaces for runtime monitoring

