# Compiler and simulator
VERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave
YOSYS = yosys

# Directories
RTL_DIR = rtl
TB_DIR = tb
BUILD_DIR = build
SYNTH_DIR = $(BUILD_DIR)/synth

# Source files
# Note: conflict_checker.v has been removed as part of pipeline optimization
VERILOG_SOURCES = $(RTL_DIR)/top.v \
                  $(RTL_DIR)/batcher.v \
                  $(RTL_DIR)/insertion.v \
                  $(RTL_DIR)/batch.v \
                  $(RTL_DIR)/conflict_manager.v
TB_SOURCES = $(TB_DIR)/tb_svm_scheduler.v

# Output files
VVP_FILE = $(BUILD_DIR)/svm_scheduler.vvp
VCD_FILE = $(BUILD_DIR)/svm_scheduler.vcd
FUNCTIONAL_LOG = $(BUILD_DIR)/functional_sim.log

NETLIST_FILE = $(SYNTH_DIR)/netlist.v
SYNTH_LOG = $(SYNTH_DIR)/synthesis.log
SYNTH_SIM_VVP = $(SYNTH_DIR)/synth_sim.vvp
SYNTH_SIM_VCD = $(SYNTH_DIR)/synth_sim.vcd
SYNTH_SIM_LOG = $(SYNTH_DIR)/synthesis_sim.log

# Create build directory if it doesn't exist
$(shell mkdir -p $(BUILD_DIR))
$(shell mkdir -p $(SYNTH_DIR))

# Default target
all: sim

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Compile Verilog sources
$(VVP_FILE): $(VERILOG_SOURCES) $(TB_SOURCES) | $(BUILD_DIR)
	$(VERILOG) -g2012 -o $@ $^

# Run simulation to generate VCD file
$(VCD_FILE): $(VVP_FILE)
	$(VVP) $< | tee $(FUNCTIONAL_LOG)

# Simulation target
sim: $(VCD_FILE)

# View waveforms
wave: $(VCD_FILE)
	$(GTKWAVE) $<

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) $(SYNTH_DIR)

# Create synthesis directory
$(SYNTH_DIR):
	mkdir -p $(SYNTH_DIR)

# Synthesis with Yosys
$(NETLIST_FILE): $(VERILOG_SOURCES) | $(SYNTH_DIR)
	$(YOSYS) -QT -l $(SYNTH_LOG) -p "read_verilog -sv $^; hierarchy -check -top top; proc; opt; fsm; opt; memory; opt; techmap -map rtl/cells.v; opt; write_verilog -simple-lhs -noattr -nohex $(NETLIST_FILE);"

# Synthesis target
synth: $(NETLIST_FILE)

# Post-synthesis simulation
$(SYNTH_SIM_VVP): $(NETLIST_FILE) $(TB_SOURCES) rtl/cells.v | $(BUILD_DIR)
	$(VERILOG) -g2012 -DGATE_LEVEL_SIM -I$(SYNTH_DIR) -o $@ rtl/cells.v $(NETLIST_FILE) $(TB_SOURCES)

$(SYNTH_SIM_VCD): $(SYNTH_SIM_VVP)
	$(VVP) $< | tee $(SYNTH_SIM_LOG)

# Run post-synthesis simulation
synth_sim: $(SYNTH_SIM_VCD)

# View post-synthesis waveforms
synth_wave: $(SYNTH_SIM_VCD)
	$(GTKWAVE) $<

.PHONY: all clean sim wave synth synth_sim synth_wave
