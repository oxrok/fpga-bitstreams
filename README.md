# oxrok FPGA bitstreams

Gateware that oxrok drives, written for it: source, build files and the
host protocol of each design. One directory per design and board.

| directory | what | board | status |
|---|---|---|---|
| [oxla-tn20k](oxla-tn20k/) | logic analyzer: 8 to 16 channels, up to 270 MS/s, 2M words of SDRAM, RLE, A/B triggers | Sipeed Tang Nano 20K | runs on a board, self-tested; oxrok driver `oxla` written, not yet released |

Built bitstreams are not in the repository; `make` in a design's directory
builds them, and the
[releases](https://github.com/oxrok/fpga-bitstreams/releases) have the ones
that were tested on a board. Vendor bitstreams do not belong here either: those go through
[oxrok-firmware](https://github.com/oxrok/oxrok-firmware) and its rules.

## A new design

Give it a directory named `design-board`, with at least:

- `README.md`: what it is, the board facts it depends on, its variants, and
  what has been checked on hardware and what has not;
- `docs/PROTOCOL.md`: what a driver needs, and nothing a driver does not;
- `rtl/`, with the vendor primitives in a thin top level and the rest
  simulable as it is;
- `sim/`, with models of what is outside the FPGA;
- a `Makefile` with the variants, `make sim`, `make prog V=...`;
- a host tool that can test a loaded bitstream with nothing connected.
