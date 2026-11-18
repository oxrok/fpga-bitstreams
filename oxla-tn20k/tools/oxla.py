#!/usr/bin/env python3
"""Bring-up tool for the oxrok logic analyzer gateware (docs/PROTOCOL.md).

    oxla.py [--clock MHZ] PORT id
    oxla.py PORT describe
    oxla.py [--clock MHZ] PORT selftest [--words N]
    oxla.py PORT capture [--div N] [--samples N] [--pre PERCENT] [--rle]
                         [--ddr] [--mode MODE] [--count N] [--a SPEC]
                         [--b SPEC] [--out FILE]

A trigger SPEC is a comma separated list of CHANNEL=KIND, where KIND is one
of 0, 1, r, f, e, as in sigrok: --a 0=r,3=1 is "channel 0 rises while
channel 3 is high". MODE is one of now, a, b, a-or-b, a-and-b, a-then-b,
b-then-a.

This is a test tool and the reference for the oxrok driver, not the driver.
"""

import argparse
import struct
import sys
import time

import serial

OP_RESET, OP_ID, OP_WREG, OP_RREG, OP_ARM, OP_STOP, OP_RMEM = 1, 2, 3, 4, 5, 6, 7

R_DIV, R_POST_WORDS, R_PRE_WORDS, R_POST_SAMPLES, R_FLAGS, R_CHMASK = 0, 1, 2, 3, 4, 5
R_TMODE, R_TCOUNT, R_CLOCK, R_A, R_B = 6, 7, 8, 0x10, 0x18
R_STATUS, R_TRIG, R_STOP, R_COUNT = 0x80, 0x81, 0x82, 0x83
R_DESC, R_BUILD, R_CLOCKS, R_CHANNELS, R_TRIGGER, R_LIMITS, R_CLOCK_HZ = (
    0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0xa0)

F_RLE, F_DDR, F_TEST = 1, 2, 4
ST_RUN, ST_TRIG, ST_DONE, ST_OVERFLOW, ST_READY = 1, 2, 4, 8, 16

MODES = ["now", "a", "b", "a-or-b", "a-and-b", "a-then-b", "b-then-a"]
CLOCKS = [81, 108, 135]             # MHz, by the value of the CLOCK register


class Oxla:
    def __init__(self, port, baud=3000000):
        self.ser = serial.Serial(port, baud, timeout=2)
        time.sleep(0.05)
        self.ser.reset_input_buffer()
        # Eight NOPs flush a half received command, then reset.
        self.ser.write(bytes(8) + bytes([OP_RESET]))
        time.sleep(0.05)
        self.ser.reset_input_buffer()
        self.read_id()

    def read_id(self):
        self.ser.write(bytes([OP_ID]))
        d = self._read(16)
        if d[:4] != b"OXLA":
            raise RuntimeError(f"not an oxla device: {d!r}")
        self.version, caps, self.channels, self.spc = d[4], d[5], d[6], d[7]
        self.clk_hz, = struct.unpack_from("<I", d, 8)
        self.mem_words, = struct.unpack_from("<I", d, 12)
        self.has_rle, self.has_ddr, self.has_adc = bool(caps & 1), bool(caps & 2), bool(caps & 4)
        self.has_clocks = bool(caps & 8)
        self.caps, self.has_desc = caps, bool(caps & 16)
        # Samples repeat their position in the words every `group` words
        # (1 unless the channel count does not divide 32).
        g = 1
        while g < 32 and self.channels % (2 * g) == 0:
            g *= 2
        self.group = self.channels // g

    def _read(self, n):
        d = self.ser.read(n)
        if len(d) != n:
            raise RuntimeError(f"short read: {len(d)} of {n} bytes")
        return d

    def wreg(self, addr, val):
        self.ser.write(struct.pack("<BBI", OP_WREG, addr, val & 0xffffffff))

    def rreg(self, addr):
        self.ser.write(bytes([OP_RREG, addr]))
        return struct.unpack("<I", self._read(4))[0]

    def variant(self):
        """The name of this bitstream in the build, from its ID: la8-ddr."""
        return (f"la{self.channels}" + ("-ddr" if self.has_ddr and self.spc == 2 else "")
                + ("-rle" if self.has_rle else "") + ("-adc" if self.has_adc else ""))

    def describe(self):
        """What the bitstream says it is: its ID and, where it has them, its
        description registers. The ID's clock is the one it is at now."""
        d = {"protocol": self.version, "caps": self.caps, "channels": self.channels,
             "samples_per_clock": self.spc, "clock_hz": self.clk_hz,
             "mem_words": self.mem_words}
        if not self.has_desc:
            return d
        # A later format adds to these and leaves them as they are; 0 is a
        # bitstream with the bit and none of the registers.
        fmt = self.rreg(R_DESC)
        if fmt == 0:
            return d
        build, clocks, channels = self.rreg(R_BUILD), self.rreg(R_CLOCKS), self.rreg(R_CHANNELS)
        trigger, limits = self.rreg(R_TRIGGER), self.rreg(R_LIMITS)
        if clocks & 255 > 8:
            raise RuntimeError(f"{clocks & 255} clocks described: there are registers for 8")
        d["description"] = {
            "format": fmt,
            "build": f"{build >> 16 & 255}.{build >> 8 & 255}.{build & 255}",
            "clocks_hz": [self.rreg(R_CLOCK_HZ + i) for i in range(clocks & 255)],
            "clock_at_start": clocks >> 8 & 255,
            "logic_channels": channels & 255,
            "analog_channels": channels >> 8 & 255,
            "analog_bits": channels >> 16 & 255,
            "trigger_terms": trigger & 255,
            "trigger_count_bits": trigger >> 8 & 255,
            "trigger_modes": [m for m in range(8) if trigger >> 16 >> m & 1],
            "div_min": limits & 255,
            "div_bits": limits >> 8 & 255,
            "rle_count_bits": limits >> 16 & 255,
        }
        return d

    def set_clock(self, mhz):
        """Change the capture clock (81, 108 or 135 MHz). Everything else
        goes back to its default and what was captured is lost. The clock
        stays as set until the next change or a new bitstream."""
        if not self.has_clocks:
            raise RuntimeError("this bitstream has a fixed clock")
        self.wreg(R_CLOCK, CLOCKS.index(mhz))
        t0 = time.time()
        time.sleep(0.02)
        while not self.rreg(R_STATUS) & ST_READY:
            if time.time() - t0 > 2:
                raise RuntimeError(f"no clock at {mhz} MHz: the SDRAM did not come back")
            time.sleep(0.01)
        self.read_id()
        if self.clk_hz != mhz * 1000000:
            raise RuntimeError(f"asked for {mhz} MHz, the device says {self.clk_hz} Hz")

    def reset(self):
        self.ser.write(bytes([OP_RESET]))

    def arm(self):
        self.ser.write(bytes([OP_ARM]))

    def stop(self):
        self.ser.write(bytes([OP_STOP]))

    def rmem(self, addr, count):
        """Read count words starting at addr (which wraps), as a tuple."""
        out = bytearray()
        while count:
            # The board's USB bridge (BL616) loses bytes when more than about
            # 10 kB arrive in one go at 3 Mbaud, so ask for 8 kB at a time.
            n = min(count, 2048)
            self.ser.write(struct.pack("<BI", OP_RMEM, addr % self.mem_words)[:4]
                           + struct.pack("<I", n)[:3])
            out += self._read(4 * n)
            addr += n
            count -= n
        return struct.unpack(f"<{len(out) // 4}I", out)

    def set_term(self, base, spec):
        mask = val = rise = fall = edge = 0
        for item in filter(None, (spec or "").split(",")):
            ch, kind = item.split("=")
            bit = 1 << int(ch)
            if kind == "0":
                mask |= bit
            elif kind == "1":
                mask |= bit
                val |= bit
            elif kind == "r":
                rise |= bit
            elif kind == "f":
                fall |= bit
            elif kind == "e":
                edge |= bit
            else:
                raise ValueError(f"trigger kind {kind!r}")
        for i, v in enumerate((mask, val, rise, fall, edge)):
            self.wreg(base + i, v)

    def wait_done(self, timeout=20):
        """Wait for the capture to end; after timeout seconds, STOP it."""
        t0 = time.time()
        while True:
            st = self.rreg(R_STATUS)
            if st & ST_DONE:
                return st
            if timeout is not None and time.time() - t0 > timeout:
                self.stop()
                timeout = None
            time.sleep(0.01)

    def first_start(self, addr):
        """The bit of the word at addr at which the first sample starts."""
        w = self.channels
        return (w - (32 * (addr % self.group)) % w) % w

    def result(self, want_words=None, rle=False):
        """After a capture: (status, words, samples, index of the trigger
        word, index of the trigger sample or None)."""
        st = self.rreg(R_STATUS)
        trig = self.rreg(R_TRIG)
        stop = self.rreg(R_STOP)
        count = self.rreg(R_COUNT)
        mem = self.mem_words
        n = count if want_words is None else min(count, want_words)
        start = (stop - n) % mem
        words = self.rmem(start, n)
        tw = ((trig & 0x1fffff) - start) % mem
        sub = (trig >> 24) & 3
        w = self.channels
        mask = (1 << w) - 1
        samples = []
        if rle:
            # A STOP with no run in progress leaves a last word that is none.
            runs = words[:-1] if n and (st >> 8) & 63 == 0 else words
            for x in runs:
                samples.extend([x & mask] * ((x >> w) + 1))
            ti = sum((x >> w) + 1 for x in words[:tw])
        else:
            # The words are a stream of bits, low bit first. The first
            # sample starts off0 bits in, and the last word has only as many
            # real bits as the status says.
            off0 = self.first_start(start)
            nbits = 32 * (n - 1) + ((st >> 8) & 63) if n else 0
            total = max(0, nbits - off0) // w
            acc, have, skip = 0, 0, off0
            for x in words:
                acc |= x << have
                have += 32
                if skip:
                    acc >>= skip
                    have -= skip
                    skip = 0
                while have >= w and len(samples) < total:
                    samples.append(acc & mask)
                    acc >>= w
                    have -= w
            ti = (32 * tw + self.first_start(start + tw) - off0) // w + sub
        if not st & ST_TRIG:
            ti = None
        return st, words, samples, tw, ti


def cmd_id(la, args):
    print(f"oxla protocol {la.version}: {la.channels} channels, "
          f"{la.clk_hz * la.spc / 1e6:g} MS/s max ({la.clk_hz / 1e6:g} MHz clock, "
          f"{la.spc} per clock), {la.mem_words} words"
          f"{', rle' if la.has_rle else ''}{', adc' if la.has_adc else ''}"
          f"{', clock 81/108/135 MHz' if la.has_clocks else ''}")
    print(f"status {la.rreg(R_STATUS):#x}")


def cmd_describe(la, args):
    import json
    print(json.dumps({"variant": la.variant(), **la.describe()}, indent=2))


def check_description(la):
    """The description registers against the ID and against what this tool
    knows of the gateware, with the clock left as it is. Gives the failures
    and the description; nothing to check on a bitstream without one."""
    d = la.describe().get("description")
    if d is None:
        print("description: none")
        return 0, None
    want = {
        "logic_channels": 0 if la.has_adc else la.channels,
        "analog_channels": 1 if la.has_adc else 0,
        "analog_bits": la.channels if la.has_adc else 0,
        "trigger_terms": 2, "trigger_count_bits": 16, "trigger_modes": list(range(len(MODES))),
        "div_min": 1 if la.has_adc else 0, "div_bits": 24,
        "rle_count_bits": 32 - la.channels if la.has_rle else 0,
        "clock_at_start": 1,
    }
    fails = [f"{k} is {d[k]}, not {v}" for k, v in want.items() if d[k] != v]
    if la.has_clocks and d["clocks_hz"] != [mhz * 1000000 for mhz in CLOCKS]:
        fails.append(f"clocks of {d['clocks_hz']} Hz, not {CLOCKS} MHz")
    for f in fails:
        print(f"  FAIL: description: {f}")
    print(f"description: build {d['build']}, clocks {d['clocks_hz']}" + ("" if fails else " ok"))
    return len(fails), d


def cmd_selftest(la, args):
    """The self test at every clock the device has, or at the one given."""
    clocks = [args.clock] if args.clock else (CLOCKS if la.has_clocks else [None])
    fails, desc = check_description(la)
    for mhz in clocks:
        if mhz:
            la.set_clock(mhz)
            print(f"--- {mhz} MHz")
            # The clock the device is at now against the one it lists for
            # this setting.
            i = CLOCKS.index(mhz)
            if desc and (i >= len(desc["clocks_hz"]) or desc["clocks_hz"][i] != la.clk_hz):
                fails += 1
                print(f"  FAIL: description: setting {i} is {la.clk_hz} Hz, not as listed")
        fails += selftest_once(la, args)
    print("selftest ok" if not fails else f"selftest FAILED ({fails})")
    return 1 if fails else 0


def selftest_once(la, args):
    """Captures of the internal test pattern (a counter, one step per sample),
    which exercise everything but the input pins: memory, triggers, RLE."""
    mask = (1 << la.channels) - 1
    fails = 0

    def check(ok, what):
        nonlocal fails
        if not ok:
            fails += 1
            print(f"  FAIL: {what}")

    def contiguous(s, step=1):
        return next((i for i in range(1, len(s)) if s[i] != (s[i-1] + step) & mask), None)

    # Memory: fill from address 0, read back, compare.
    for div in (0, 3):
        ddr = F_DDR if la.has_ddr and div == 0 else 0
        la.reset()
        la.wreg(R_FLAGS, F_TEST | ddr)
        la.wreg(R_DIV, div)
        la.wreg(R_POST_WORDS, args.words - 1)
        la.arm()
        la.wait_done()
        t0 = time.time()
        st, words, s, tw, ti = la.result()
        dt = time.time() - t0
        bad = sum(1 for i, v in enumerate(s) if v != (i & mask))
        print(f"memory, div {div}: status {st:#x}, {len(words)} words read at "
              f"{len(words) * 4 / dt / 1e3:.0f} kB/s, {bad} bad samples of {len(s)}")
        check(bad == 0 and len(words) == args.words and tw == 0
              and not st & ST_OVERFLOW, "memory")
        if bad:
            first = next(i for i, v in enumerate(s) if v != (i & mask))
            print(f"  first bad sample {first}: {s[first]:#x}")

    # Triggers, at full rate, with pre-trigger data.
    ddr = F_DDR if la.has_ddr else 0
    cases = [
        ("a", "5=r", "", 0, lambda v: v & 0x3f == 0x20),
        ("b", "", "0=1,1=0,2=1,3=1,4=0,5=1,6=0,7=1", 0, lambda v: v & 0xff == 0xad),
        ("a-or-b", "5=r", "3=f", 0, lambda v: v & 0x3f == 0x20 or v & 0xf == 0),
        ("a-and-b", "5=r", "4=f,0=0", 0, lambda v: v & 0x3f == 0x20),
        ("a-then-b", "5=r", "3=f", 2, lambda v: v & 0x3f == 0x30),
        ("b-then-a", "5=r", "3=f", 0, lambda v: v & 0x3f == 0x20),
        ("a", "2=e", "", 999, lambda v: v & 0x3 == 0),
    ]
    for mode, a, b, count, ok in cases:
        la.reset()
        la.wreg(R_FLAGS, F_TEST | ddr)
        la.wreg(R_TMODE, MODES.index(mode))
        la.wreg(R_TCOUNT, count)
        la.set_term(R_A, a)
        la.set_term(R_B, b)
        la.wreg(R_PRE_WORDS, 500)
        la.wreg(R_POST_WORDS, 1500)
        la.arm()
        la.wait_done()
        st, words, s, tw, ti = la.result(2001)
        good = (st & ST_TRIG and not st & ST_OVERFLOW and len(words) == 2001
                and tw == 500 and contiguous(s) is None and ok(s[ti]))
        print(f"trigger {mode} (a: {a or '-'}, b: {b or '-'}, count {count}): "
              f"sample {ti} = {s[ti]:#x} {'ok' if good else 'WRONG'}")
        check(good, f"trigger {mode}")

    # A capture ended by a count of samples.
    la.reset()
    la.wreg(R_FLAGS, F_TEST | ddr)
    la.wreg(R_POST_WORDS, la.mem_words - 1)
    la.wreg(R_POST_SAMPLES, 12345)
    la.arm()
    la.wait_done()
    st, words, s, tw, ti = la.result()
    print(f"sample limit: {len(s)} samples in {len(words)} words")
    check(len(s) == 12346 and contiguous(s) is None, "sample limit")

    if la.has_rle:
        # The counter changes on every sample, the worst case for RLE: a
        # word per sample. Fine at a quarter of the clock, an overflow at
        # full rate.
        la.reset()
        la.wreg(R_FLAGS, F_TEST | F_RLE)
        la.wreg(R_DIV, 3)
        la.wreg(R_TMODE, MODES.index("a"))
        la.set_term(R_A, "0=1,1=1,2=1,3=1,4=1,5=1,6=1,7=1")
        la.wreg(R_PRE_WORDS, 100)
        la.wreg(R_POST_WORDS, la.mem_words - 1)
        la.wreg(R_POST_SAMPLES, 50000)
        la.arm()
        la.wait_done()
        st, words, s, tw, ti = la.result(rle=True)
        after = sum((x >> la.channels) + 1 for x in words[tw:])
        print(f"rle: {len(words)} words, {len(s)} samples, {after} from the trigger on")
        check(not st & ST_OVERFLOW and after == 50001 and contiguous(s) is None
              and words[tw] & 0xff == 0xff, "rle")

        la.reset()
        la.wreg(R_FLAGS, F_TEST | F_RLE)
        la.wreg(R_POST_WORDS, la.mem_words - 1)
        la.arm()
        st = la.wait_done(2)
        print(f"rle at full rate on a counter: status {st:#x}")
        check(st & ST_OVERFLOW, "rle overflow is reported")

        # The pins, whatever is on them: the sample count must be exact.
        la.reset()
        la.wreg(R_FLAGS, F_RLE)
        la.wreg(R_POST_WORDS, la.mem_words - 1)
        la.wreg(R_POST_SAMPLES, 5000000)
        la.arm()
        la.wait_done()
        st, words, s, tw, ti = la.result(rle=True)
        n = sum((x >> la.channels) + 1 for x in words)
        print(f"rle on the pins: {len(words)} words for {n} samples")
        check(n == 5000001 and not st & ST_OVERFLOW, "rle on the pins")

    return fails


def cmd_capture(la, args):
    rle = args.rle
    if rle and not la.has_rle:
        sys.exit("this bitstream has no RLE")
    pre = args.samples * args.pre // 100
    post = args.samples - pre
    la.reset()
    la.wreg(R_DIV, args.div)
    la.wreg(R_FLAGS, (F_RLE if rle else 0) | (F_DDR if args.ddr else 0))
    la.wreg(R_TMODE, MODES.index(args.mode))
    la.wreg(R_TCOUNT, args.count)
    la.set_term(R_A, args.a)
    la.set_term(R_B, args.b)
    if rle:
        la.wreg(R_PRE_WORDS, 0)
        la.wreg(R_POST_WORDS, la.mem_words - 2)
        la.wreg(R_POST_SAMPLES, post)
    else:
        la.wreg(R_PRE_WORDS, -(-pre * la.channels // 32))
        la.wreg(R_POST_WORDS, -(-post * la.channels // 32))
    la.arm()
    st = la.wait_done(args.timeout)
    st, words, s, tw, ti = la.result(rle=rle)
    rate = la.clk_hz * (2 if args.ddr else 1) / (args.div + 1)
    print(f"status {st:#x}: {len(words)} words, {len(s)} samples at {rate / 1e6:g} MS/s, "
          f"trigger at sample {ti}"
          f"{', OVERFLOW' if st & ST_OVERFLOW else ''}")
    if args.out:
        fmt = "<%dH" if la.channels > 8 else "<%dB"
        with open(args.out, "wb") as f:
            f.write(struct.pack(fmt % len(s), *s))
    lo = max(0, ti - 8) if ti is not None else 0
    w = la.channels
    for i in range(lo, min(len(s), lo + 24)):
        print(f"{i:8d} {s[i]:0{w}b}{'  <- trigger' if i == ti else ''}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("port")
    p.add_argument("--baud", type=int, default=3000000)
    p.add_argument("--clock", type=int, choices=CLOCKS,
                   help="capture clock in MHz (stays set); selftest tries all without it")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("id")
    sub.add_parser("describe")
    s = sub.add_parser("selftest")
    s.add_argument("--words", type=int, default=100000)
    c = sub.add_parser("capture")
    c.add_argument("--div", type=int, default=0)
    c.add_argument("--samples", type=int, default=10000)
    c.add_argument("--pre", type=int, default=10)
    c.add_argument("--rle", action="store_true")
    c.add_argument("--ddr", action="store_true")
    c.add_argument("--mode", choices=MODES, default="now")
    c.add_argument("--count", type=int, default=0)
    c.add_argument("--a")
    c.add_argument("--b")
    c.add_argument("--timeout", type=float, default=5)
    c.add_argument("--out")
    args = p.parse_args()
    la = Oxla(args.port, args.baud)
    if args.clock and args.cmd != "selftest":
        la.set_clock(args.clock)
    return {"id": cmd_id, "describe": cmd_describe, "selftest": cmd_selftest,
            "capture": cmd_capture}[args.cmd](la, args)


if __name__ == "__main__":
    sys.exit(main())
