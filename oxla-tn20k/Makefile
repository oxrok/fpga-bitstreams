# oxrok logic analyzer gateware for the Sipeed Tang Nano 20K.
#
# Open toolchain: yosys, nextpnr-himbaechel (Gowin) and apycula's gowin_pack.
# `make venv` installs the last two into .venv (nextpnr as the YoWASP build).
#
#   make            all variants          make la16-rle      one variant
#   make sim        simulation            make prog V=la16-rle   load into SRAM
#   make la16-rle SEED=3 BUILD=build/s3   another placement, elsewhere
#   make flash V=la16-rle   write to the board's flash
#   make release VERSION=0.1.0 PORT=/dev/cu.usbserial-XXXX1
#                   build all, self test each on the board, pack them
#   make publish VERSION=0.1.0    that pack as a GitHub release

YOSYS   ?= yosys
NEXTPNR ?= .venv/bin/yowasp-nextpnr-himbaechel-gowin
PACK    ?= .venv/bin/gowin_pack
LOADER  ?= openFPGALoader
PYTHON  ?= .venv/bin/python

DEVICE = GW2AR-LV18QN88C8/I7
FAMILY = GW2A-18C
BOARD  = cst
BUILD ?= build
BAUD  ?= 3000000

# Placement seed for nextpnr; empty for its default.
SEED ?=

# The capture clock is set at run time, up to this many MHz, and nextpnr
# must meet it with MARGIN percent to spare or the build fails. Builds that passed its report with less have failed on the
# board (150 MHz reported for a 135 MHz clock, for one); with 15% none has.
# When a build fails here, try another SEED.
MARGIN ?= 15
MAX_MHZ = 135
FREQ := $(shell echo $$(( $(MAX_MHZ) * (100 + $(MARGIN)) / 100 )))

# Phase of the SDRAM clock after the system clock, in sixteenths of a period.
SD_PHASE ?= 13
SD_PSDA := $(shell python3 -c "print(format($(SD_PHASE) % 16, '04b'))")
SD_DUTY := $(shell python3 -c "print(format(($(SD_PHASE) + 8) % 16, '04b'))")

RTL = rtl/oxla_top.v rtl/oxla_core.v rtl/oxla_host.v rtl/oxla_capture.v \
      rtl/oxla_fifo.v rtl/oxla_sdram.v rtl/oxla_uart.v

# name : channels : samples per clock : RLE : ADC : seed (optional: a
# placement that meets the margin, for a variant whose default does not)
VARIANTS = \
    la16-rle:16:1:1:0 \
    la16:16:1:0:0 \
    la14-ddr:14:2:0:0 \
    la8-rle:8:1:1:0 \
    la8-ddr:8:2:0:0 \
    la8-adc:8:1:0:1

NAMES = $(foreach v,$(VARIANTS),$(word 1,$(subst :, ,$(v))))

all: $(NAMES)

define variant
$(1): $(BUILD)/$(1)/oxla.fs

$(BUILD)/$(1)/oxla.cst: $(BOARD)/common.cst $(BOARD)/ch0-7.cst $(BOARD)/ch8-15.cst $(BOARD)/adc.cst
	@mkdir -p $(BUILD)/$(1)
	cat $(BOARD)/common.cst $(BOARD)/ch0-7.cst $(BOARD)/ch8-15.cst \
	    $(if $(filter 1,$(5)),$(BOARD)/adc.cst) | awk -v w=$(2) \
	    '{ if (match($$$$0, /ch\[[0-9]+\]/) && substr($$$$0, RSTART + 3, RLENGTH - 4) + 0 >= w) next; print }' > $$@

$(BUILD)/$(1)/oxla.json: $(RTL) Makefile
	@mkdir -p $(BUILD)/$(1)
	$(YOSYS) -q -l $(BUILD)/$(1)/yosys.log -p "read_verilog -DSD_PSDA=\"$(SD_PSDA)\" -DSD_DUTY=\"$(SD_DUTY)\" \
	    $(if $(filter 1,$(5)),-DOXLA_ADC) $(RTL); \
	    hierarchy -top oxla_top -chparam BAUD $(BAUD) \
	        -chparam W $(2) -chparam P $(3) -chparam RLE $(4) -chparam ADC $(5); \
	    synth_gowin -top oxla_top -family gw2a -json $$@"

$(BUILD)/$(1)/oxla_pnr.json: $(BUILD)/$(1)/oxla.json $(BUILD)/$(1)/oxla.cst
	$(NEXTPNR) --json $$< --write $$@ --device $(DEVICE) --vopt family=$(FAMILY) \
	    --vopt cst=$(BUILD)/$(1)/oxla.cst --freq $(FREQ) $(if $(SEED),--seed $(SEED),$(if $(6),--seed $(6))) --log $(BUILD)/$(1)/nextpnr.log -q

$(BUILD)/$(1)/oxla.fs: $(BUILD)/$(1)/oxla_pnr.json
	$(PACK) -c -d $(FAMILY) -o $$@ $$<
endef

$(foreach v,$(VARIANTS),$(eval $(call variant,$(word 1,$(subst :, ,$(v))),$(word 2,$(subst :, ,$(v))),$(word 3,$(subst :, ,$(v))),$(word 4,$(subst :, ,$(v))),$(word 5,$(subst :, ,$(v))),$(word 6,$(subst :, ,$(v))))))

prog: $(BUILD)/$(V)/oxla.fs
	$(LOADER) -b tangnano20k $<

flash: $(BUILD)/$(V)/oxla.fs
	$(LOADER) -b tangnano20k -f $<

# A release is the bitstreams that passed the self test on a board, and
# only those: every variant is loaded and tested, and one failure stops it.
# They go out as one archive (a .fs is 7 MB of text and packs to 80 kB),
# under the names oxrok looks them up by.
RELEASE = $(BUILD)/release
TAG     = oxla-tn20k-v$(VERSION)
PACKAGE = oxla-tn20k-$(VERSION).tar.gz

release: all
	@test -n "$(VERSION)" || { echo "VERSION=x.y.z is needed"; false; }
	@test -n "$(PORT)" || { echo "PORT=... is needed: the board's serial port, the second of its two"; false; }
	@test -z "$$(git status --porcelain .)" || { echo "commit first: a release is built from a commit"; false; }
	@rm -rf $(RELEASE) && mkdir -p $(RELEASE)
	@for v in $(NAMES); do \
	    echo "== $$v"; \
	    $(LOADER) -b tangnano20k $(BUILD)/$$v/oxla.fs > /dev/null && sleep 1 && \
	    $(PYTHON) tools/oxla.py $(PORT) id | head -1 | sed "s/^/$$v: /" | tee -a $(RELEASE)/TESTED && \
	    { $(PYTHON) tools/oxla.py $(PORT) selftest > $(RELEASE)/$$v.log 2>&1; ok=$$?; \
	      tail -1 $(RELEASE)/$$v.log; test $$ok = 0; } && \
	    cp $(BUILD)/$$v/oxla.fs $(RELEASE)/oxla-tn20k-$$v.fs || \
	    { echo "$$v failed: $(RELEASE)/$$v.log"; exit 1; }; \
	done
	@{ echo "oxla-tn20k $(VERSION), commit $$(git rev-parse HEAD)"; \
	   echo "Built $$(date -u +%Y-%m-%d) with $$($(YOSYS) -V | cut -d' ' -f1-2),"; \
	   echo "$$($(NEXTPNR) --version 2>&1 | sed 's/.*(Version \(.*\))/\1/') (YoWASP)" \
	        "and apycula $$($(PYTHON) -c 'import importlib.metadata as m; print(m.version("apycula"))')."; \
	   echo "Every file passed tools/oxla.py selftest on one Tang Nano 20K, at 81, 108 and"; \
	   echo "135 MHz, loaded into the FPGA as it is here. What each said it was:"; \
	   echo; cat $(RELEASE)/TESTED; } > $(RELEASE)/NOTES.txt
	@rm $(RELEASE)/TESTED $(RELEASE)/*.log
	cd $(RELEASE) && tar -czf $(PACKAGE) oxla-tn20k-*.fs && shasum -a 256 $(PACKAGE) oxla-tn20k-*.fs > SHA256SUMS
	@echo "$(RELEASE)/$(PACKAGE): $(words $(NAMES)) bitstreams, all passed"

publish:
	@test -f $(RELEASE)/$(PACKAGE) || { echo "make release VERSION=$(VERSION) PORT=... first"; false; }
	git tag $(TAG) $$(sed -n '1s/.*commit //p' $(RELEASE)/NOTES.txt)
	git push origin $(TAG)
	gh release create $(TAG) --title "oxla-tn20k $(VERSION)" --notes-file $(RELEASE)/NOTES.txt \
	    $(RELEASE)/$(PACKAGE) $(RELEASE)/SHA256SUMS

venv:
	uv venv --python 3.12 .venv
	uv pip install --python .venv/bin/python apycula yowasp-nextpnr-himbaechel-gowin pyserial

sim:
	$(MAKE) -C sim

clean:
	rm -rf build sim/obj_dir

.PHONY: all prog flash release publish venv sim clean $(NAMES)
