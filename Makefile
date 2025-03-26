# Compiler and simulator
VERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave

# Directories
RTL_DIR = rtl
TB_DIR = tb
BUILD_DIR = build

# Source files
VERILOG_SOURCES = $(RTL_DIR)/top.v \
                  $(RTL_DIR)/conflict_detection.v \
                  $(RTL_DIR)/conflict_checker.v \
                  $(RTL_DIR)/insertion.v \
                  $(RTL_DIR)/batch.v
TB_SOURCES = $(TB_DIR)/tb_svm_scheduler.v

# Output files
VVP_FILE = $(BUILD_DIR)/svm_scheduler.vvp
VCD_FILE = $(BUILD_DIR)/svm_scheduler.vcd

# Create build directory if it doesn't exist
$(shell mkdir -p $(BUILD_DIR))

# Default target
all: sim

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Compile Verilog sources
$(VVP_FILE): $(VERILOG_SOURCES) $(TB_SOURCES) | $(BUILD_DIR)
	$(VERILOG) -g2012 -o $@ $^

# Run simulation to generate VCD file
$(VCD_FILE): $(VVP_FILE)
	$(VVP) $<

# Simulation target
sim: $(VCD_FILE)

# View waveforms
wave: $(VCD_FILE)
	$(GTKWAVE) $<

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean sim wave
