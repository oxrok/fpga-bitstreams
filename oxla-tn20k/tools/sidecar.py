#!/usr/bin/env python3
"""Writes the description that goes with a bitstream: FILE.fs.json.

    sidecar.py --port PORT --variant NAME --version X.Y.Z --commit HASH [--default] FILE.fs

The bitstream must be the one running on the board at PORT: what the file
says about it is what the board answered, not what the build meant it to
be. The part's ID code is read from the .fs itself. Used by `make release`,
after the self test; the format is in docs/SIDECAR.md.
"""

import argparse
import datetime
import hashlib
import json
import sys

from oxla import Oxla


def fs_idcode(text):
    """The ID code in the header of a .fs file: the record with key 06."""
    for line in text.splitlines():
        line = line.strip()
        if len(line) == 64 and set(line) <= {"0", "1"} and int(line[:8], 2) & 0x7f == 0x06:
            return int(line[32:], 2)
    raise RuntimeError("no ID code in the .fs file")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("fs")
    p.add_argument("--port", required=True)
    p.add_argument("--variant", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--default", action="store_true",
                   help="the variant a board gets when none is asked for")
    args = p.parse_args()

    data = open(args.fs, "rb").read()
    la = Oxla(args.port)
    d = la.describe()
    desc = d.pop("description", None)
    if la.variant() != args.variant:
        raise RuntimeError(f"the board runs {la.variant()}, not {args.variant}")
    if desc is None or desc["build"] != args.version:
        raise RuntimeError(f"the board runs build {desc and desc['build']}, not {args.version}")

    # The ID as the bitstream gives it when it starts, not at the clock the
    # self test left it at.
    d["clock_hz"] = desc["clocks_hz"][desc["clock_at_start"]]

    json.dump({
        "format": 1,
        "design": "oxla",
        "variant": args.variant,
        "default": args.default,
        "version": args.version,
        "commit": args.commit,
        "sha256": hashlib.sha256(data).hexdigest(),
        "target": {
            "board": "sipeed-tang-nano-20k",
            "fpga": "GW2AR-18",
            "idcode": f"{fs_idcode(data.decode('ascii')):#010x}",
            "usb": {"vid": "0403", "pid": "6010",
                    "manufacturer": "SIPEED", "product": "USB Debugger"},
            "loader": "gowin-jtag-sram",
        },
        "id": d,
        "description": desc,
        "tested": {"date": datetime.date.today().isoformat(), "selftest": "pass"},
    }, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
