# SVM Transaction Scheduler High-level Design Specs
A 4-stage pipeline for reading SVM transactions and creating batches that contain non-conflicting transactions. There are two diagrams below, this prototype implements the bottom 4 stage pipeline diagram. 

## Project structure
svm-hw-scheduler/
- Makefile           # For building the project and running tests.
- rtl/               # Verilog source files
- tb/                # test bench with testcases.
- sim/               # to place output from simulations
- src                # Old source. Ignore this folder in this branch

## Design Implementation Overview & Components
- *rtl/top.v*: Responsible for receiving transaction
- conflict_checker.v: responsible for forward transaction to a particular batchID's filter engine.
- *rtl/filter_engine.v*: responsible for applying a filter on the transaction against the batch's current filter rules that is constructed as transactions gets added to the the current batch.
- *rtl/insertion.v*: Responsible for signaling to the batch to accept transaction from the filter_engine
- *rtl/batch.v*: Responsible for adding a deconflicted transaction from the filter engine into the batch. Max of 48 transactions per batch.
- *tb/tb_svm_scheduler.v/*: Test cases with transactions that conflict and do not.

## Prerequisite
- Install verilog simulator(e.g icarius) and Wave form viewer(e.g gtkwave)
- Clone the repo
- cd to svm-hw-schduler
- type `make sim`

## Tests
The test bench contains several transactions tests that conflict and some that do not
conflict. 

- Transactions 1 & 2 conflicts when attemptign to add 2 after 1 was added, so 2 will not be added to the batch
- Transactions 3 & 4 conflicts when attempting to add 4 after 3 was added, so 4 will not be added to the batch
- Transactions 5 & 6 conflicts when attempting to add 6 after 5 was added, so 6 will not be added to the batch
- Transactions 7 & 8 do not conflict and will be added
- Transactions 9 & 10 conflicts when attempting to add 10 after 9 was added, so 10 will not be added.

### Assumptions
- Each transaction has max of 1024 read and write dependencies account list.

### TODO: Improvement points
- Parallelism -  Multiple Conflict checkers working against multiple batches 



