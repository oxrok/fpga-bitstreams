# Simulation with Verilator (5.x, for --timing).

RTL = ../rtl/oxla_core.v ../rtl/oxla_host.v ../rtl/oxla_capture.v \
      ../rtl/oxla_fifo.v ../rtl/oxla_sdram.v ../rtl/oxla_uart.v
FLAGS = --binary --timing -Wno-fatal -Wno-WIDTH -Wno-BLKSEQ -Wno-TIMESCALEMOD \
        -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -O2 --top-module tb

# W:P:RLE:clock (0 = 81, 1 = 108, 2 = 135 MHz)
CONFIGS = 16:1:1:1 16:1:1:2 16:1:0:0 8:1:1:1 8:2:0:2 14:2:0:1 14:2:0:2

all: $(foreach c,$(CONFIGS),run-$(subst :,-,$(c)))

run-%:
	@mkdir -p obj_dir
	verilator $(FLAGS) -GW=$(word 1,$(subst -, ,$*)) -GP=$(word 2,$(subst -, ,$*)) \
	    -GRLE=$(word 3,$(subst -, ,$*)) -GCLKSEL=$(word 4,$(subst -, ,$*)) --Mdir obj_dir/$* -o tb tb.sv sdram_model.v $(RTL) \
	    > obj_dir-$*.log 2>&1 || (cat obj_dir-$*.log; false)
	@rm -f obj_dir-$*.log
	./obj_dir/$*/tb

.PHONY: all
