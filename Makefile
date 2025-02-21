VERILOG = iverilog
VVP = vvp
WAVE_VIEWER = gtkwave

RTL_SRCS = rtl/top.v rtl/conflict_checker.v rtl/filter_engine.v rtl/insertion.v rtl/batch.v
TB_SRCS = tb/tb_svm_scheduler.v

.PHONY: all clean sim wave

all: sim

sim: svm_scheduler.vvp
	$(VVP) svm_scheduler.vvp

svm_scheduler.vvp: $(RTL_SRCS) $(TB_SRCS)
	$(VERILOG) -o svm_scheduler.vvp $(RTL_SRCS) $(TB_SRCS)

wave: sim
	$(WAVE_VIEWER) svm_scheduler.vcd &

clean:
	rm -f ./sim/*.vvp ./sim/*.vcd
