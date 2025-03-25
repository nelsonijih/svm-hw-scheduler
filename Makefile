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
TB_SIMPLIFIED = $(TB_DIR)/tb_simplified.v
TB_PERFORMANCE = $(TB_DIR)/tb_performance_comparison.v

# Create build directory if it doesn't exist
$(shell mkdir -p $(BUILD_DIR))

# Default target
all: sim

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/svm_scheduler.vvp: $(VERILOG_SOURCES) $(TB_SOURCES) | $(BUILD_DIR)
	$(VERILOG) -g2012 \
		-o $@ $(VERILOG_SOURCES) $(TB_SOURCES)

$(BUILD_DIR)/simplified.vvp: $(VERILOG_SOURCES) $(TB_SIMPLIFIED) | $(BUILD_DIR)
	$(VERILOG) -g2012 \
		-o $@ $(VERILOG_SOURCES) $(TB_SIMPLIFIED)

$(BUILD_DIR)/performance.vvp: $(VERILOG_SOURCES) $(TB_PERFORMANCE) | $(BUILD_DIR)
	$(VERILOG) -g2012 \
		-o $@ $(VERILOG_SOURCES) $(TB_PERFORMANCE)

sim: $(BUILD_DIR)/svm_scheduler.vvp
	$(VVP) $<

simplified: $(BUILD_DIR)/simplified.vvp
	$(VVP) $<

performance: $(BUILD_DIR)/performance.vvp
	$(VVP) $<

wave: sim
	$(GTKWAVE) $(BUILD_DIR)/svm_scheduler.vcd

wave-simplified: simplified
	$(GTKWAVE) $(BUILD_DIR)/simplified.vcd

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean sim wave simplified wave-simplified performance
