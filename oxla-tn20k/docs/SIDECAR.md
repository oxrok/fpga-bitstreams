# The description beside a bitstream: `NAME.fs.json`

Every bitstream of a release has a JSON file beside it, of the same name
with `.json` added. It says what the bitstream is and what it is for, so
that a host can list a board as the analyzer it would be, and pick the
file for it, before anything is loaded. oxrok's `oxla-tn20k` driver has
no table of variants: it reads these.

`make release` writes it, after the self test, with `tools/sidecar.py`:
`id` and `description` are what the bitstream answered on the board, not
what the build meant it to be. Once a bitstream is loaded the device's own
answers are what counts; a host that finds them different from this file
believes the device.

```json
{
  "format": 1,
  "design": "oxla",
  "variant": "la8-ddr",
  "default": false,
  "version": "0.2.0",
  "commit": "…",
  "sha256": "…",
  "target": {
    "board": "sipeed-tang-nano-20k",
    "fpga": "GW2AR-18",
    "idcode": "0x0000081b",
    "usb": { "vid": "0403", "pid": "6010", "manufacturer": "SIPEED", "product": "USB Debugger" },
    "loader": "gowin-jtag-sram"
  },
  "id": {
    "protocol": 1, "caps": 26, "channels": 8, "samples_per_clock": 2,
    "clock_hz": 108000000, "mem_words": 2097152
  },
  "description": { "format": 1, "build": "0.2.0", "clocks_hz": [81000000, 108000000, 135000000], "…": "…" },
  "tested": { "date": "2026-11-18", "selftest": "pass" }
}
```

| field | |
|---|---|
| `format` | 1. A reader ignores fields it does not know, and a file whose format it does not know |
| `design` | `oxla`: the host protocol of [PROTOCOL.md](PROTOCOL.md) |
| `variant` | the name in the build, which `bitstream=` takes in oxrok |
| `default` | true on the one variant a board gets when none is asked for |
| `version`, `commit` | the release, and the commit of this repository it was built from |
| `sha256` | of the `.fs` file, lowercase hex. A host checks it before it loads the file |
| `target.board` | the board the pins are for |
| `target.fpga`, `target.idcode` | the part, and its JTAG ID code as the `.fs` has it. A host reads the FPGA's and loads nothing into another |
| `target.usb` | how the board shows on USB: the ids and strings of its debugger. Other boards can show the same, which is why the ID code is checked |
| `target.loader` | how the file gets in: `gowin-jtag-sram`, the load over JTAG that is gone at power off |
| `id` | the fields of the ID the bitstream gives when it starts: `caps` is the capability byte as it is |
| `description` | the registers from `90` as `tools/oxla.py describe` prints them |
| `tested` | the day it passed `tools/oxla.py selftest` on a board |
