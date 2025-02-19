# SVM Transaction Scheduler High-level Design Specs
A scheduler that reads from stream of transactions and checks against available maximum list of 256 batches(storage buckets), and insert in any of the first batch that a transaction does not conflict with other transactions in the batch using XOR detections 

<img width="1039" alt="Screenshot 2025-02-19 at 2 59 22 PM" src="https://github.com/user-attachments/assets/07f2cf3f-52c6-48f4-9b5d-741e92b90378" />

Assumptions
- Storage buckets for storing all 256 batches is implemented and available. in some BRAM or SRAM.
- Transaction stream buffer is impelemnted and supports simultaneous reads and writes. 
- The top level interfaces for reading in inputs and writing out outputs are available.

## Design Overview
- Supports up to 256 concurrent active batches,and 48 transactions per batch.
- 64-bit for account/program IDs
- Max of 1024 dependency entries for reads/writes dependencies per transaction

- top.v module
- batch.v module
- conflict_checker.v module
- transaction.v module(most for debuging purposes for now)

### Improvement points
- Multiple Conflict checkers can be instantiated and run simultaneously against different batches.
- Enable simultaneous insertion of new transactions into a batch(bucket) if no conflict exists. 

## Components

### 1. Top Module (`top.v`)
- Top level connecting and instantiating all other components including 256 batch instances(buckets)
- Parameters:
  - `TX_PER_BATCH`: Maximum transactions per batch (48)
  - `NUM_DEPENDENCIES`: Number of dependency entries (1024)
  - `ACCOUNT_WIDTH`: Width of account/program IDs (64 bits)
  - `MAX_BATCHES`: This is the max number of batches(buckets) we can work on at a time.

### 2. Conflict Checker (`conflict_checker.v`)
- TODO: Performs conflict detection against transaction at hand and against a set of batches(buckets) that may or may not be full.
- Parameters:
  - `NUM_DEPENDENCIES`: 1024 entries per transaction
  - `ACCOUNT_WIDTH`: 64-bit account/program IDs

### 3. Batch Module (`batch.v`)
- Grouped transactions that do not conflict with other transactions in the batch.
- Batch status (full, busy, ready)
- Parameters:
  - `TX_PER_BATCH`: 48 maximum transactions per batch
  - `ACCOUNT_WIDTH`: 64-bit account/program IDs

### 4. Transaction Module (`transaction.v`)
- Represents individual transactions with corresponding read/write dependencies. Used for debugging purposes for now.
- Parameters:
  - `NUM_DEPENDENCIES`: 1024 entries per read and write for each transaction. TODO: This needs to be expanded to support 2^64 case.
  - `ACCOUNT_WIDTH`: 64-bit account/program IDs
