# oxrok logic analyzer gateware for the Sipeed Tang Nano 20K.
#
# Open toolchain: yosys, nextpnr-himbaechel (Gowin) and apycula's gowin_pack.
# `make venv` installs the last two into .venv (nextpnr as the YoWASP build).
#
#   make            all variants          make la16-108      one variant
#   make sim        simulation            make prog V=la16-108   load into SRAM
#   make la16-135 SEED=3 BUILD=build/s3   another placement, elsewhere
#   make flash V=la16-108   write to the board's flash

YOSYS   ?= yosys
NEXTPNR ?= .venv/bin/yowasp-nextpnr-himbaechel-gowin
PACK    ?= .venv/bin/gowin_pack
LOADER  ?= openFPGALoader

DEVICE = GW2AR-LV18QN88C8/I7
FAMILY = GW2A-18C
BOARD  = cst
BUILD ?= build
BAUD  ?= 3000000

# Placement seed for nextpnr; empty for its default.
SEED ?=

# nextpnr must meet the clock with this much to spare, in percent, or the
# build fails. Builds that passed its report with less have failed on the
# board (150 MHz reported for a 135 MHz clock, for one); with 15% none has.
# When a build fails here, try another SEED.
MARGIN ?= 15

# Phase of the SDRAM clock after the system clock, in sixteenths of a period.
SD_PHASE ?= 13
SD_PSDA := $(shell python3 -c "print(format($(SD_PHASE) % 16, '04b'))")
SD_DUTY := $(shell python3 -c "print(format(($(SD_PHASE) + 8) % 16, '04b'))")

RTL = rtl/oxla_top.v rtl/oxla_core.v rtl/oxla_host.v rtl/oxla_capture.v \
      rtl/oxla_fifo.v rtl/oxla_sdram.v rtl/oxla_uart.v

# name : clock MHz : channels : samples per clock : RLE : ADC
VARIANTS = \
    la16-108:108:16:1:0:0 \
    la16-108-rle:108:16:1:1:0 \
    la16-54-rle:54:16:1:1:0 \
    la16-135:135:16:1:0:0 \
    la14-216-ddr:108:14:2:0:0 \
    la14-270-ddr:135:14:2:0:0 \
    la8-108-rle:108:8:1:1:0 \
    la8-216-ddr:108:8:2:0:0 \
    la8-270-ddr:135:8:2:0:0 \
    la8-54-adc:54:8:1:0:1

NAMES = $(foreach v,$(VARIANTS),$(word 1,$(subst :, ,$(v))))

all: $(NAMES)

define variant
$(1): $(BUILD)/$(1)/oxla.fs

$(BUILD)/$(1)/oxla.cst: $(BOARD)/common.cst $(BOARD)/ch0-7.cst $(BOARD)/ch8-15.cst $(BOARD)/adc.cst
	@mkdir -p $(BUILD)/$(1)
	cat $(BOARD)/common.cst $(BOARD)/ch0-7.cst $(BOARD)/ch8-15.cst \
	    $(if $(filter 1,$(6)),$(BOARD)/adc.cst) | awk -v w=$(3) \
	    '{ if (match($$$$0, /ch\[[0-9]+\]/) && substr($$$$0, RSTART + 3, RLENGTH - 4) + 0 >= w) next; print }' > $$@

$(BUILD)/$(1)/oxla.json: $(RTL) Makefile
	@mkdir -p $(BUILD)/$(1)
	$(YOSYS) -q -l $(BUILD)/$(1)/yosys.log -p "read_verilog -DSD_PSDA=\"$(SD_PSDA)\" -DSD_DUTY=\"$(SD_DUTY)\" \
	    $(if $(filter 1,$(6)),-DOXLA_ADC) $(RTL); \
	    hierarchy -top oxla_top -chparam CLK_MHZ $(2) -chparam BAUD $(BAUD) \
	        -chparam W $(3) -chparam P $(4) -chparam RLE $(5) -chparam ADC $(6); \
	    synth_gowin -top oxla_top -family gw2a -json $$@"

$(BUILD)/$(1)/oxla_pnr.json: $(BUILD)/$(1)/oxla.json $(BUILD)/$(1)/oxla.cst
	$(NEXTPNR) --json $$< --write $$@ --device $(DEVICE) --vopt family=$(FAMILY) \
	    --vopt cst=$(BUILD)/$(1)/oxla.cst --freq $$(shell echo $$$$(( $(2) * (100 + $(MARGIN)) / 100 ))) $(if $(SEED),--seed $(SEED)) --log $(BUILD)/$(1)/nextpnr.log -q

$(BUILD)/$(1)/oxla.fs: $(BUILD)/$(1)/oxla_pnr.json
	$(PACK) -c -d $(FAMILY) -o $$@ $$<
endef

$(foreach v,$(VARIANTS),$(eval $(call variant,$(word 1,$(subst :, ,$(v))),$(word 2,$(subst :, ,$(v))),$(word 3,$(subst :, ,$(v))),$(word 4,$(subst :, ,$(v))),$(word 5,$(subst :, ,$(v))),$(word 6,$(subst :, ,$(v))))))

prog: $(BUILD)/$(V)/oxla.fs
	$(LOADER) -b tangnano20k $<

flash: $(BUILD)/$(V)/oxla.fs
	$(LOADER) -b tangnano20k -f $<

venv:
	uv venv --python 3.12 .venv
	uv pip install --python .venv/bin/python apycula yowasp-nextpnr-himbaechel-gowin pyserial

sim:
	$(MAKE) -C sim

clean:
	rm -rf build sim/obj_dir

.PHONY: all prog flash venv sim clean $(NAMES)
