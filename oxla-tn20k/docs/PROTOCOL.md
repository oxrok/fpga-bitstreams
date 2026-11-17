# Host protocol

Version 1. A UART at 3,000,000 baud, 8N1, no flow control, on the board's
own USB serial port (the second of the two ports the BL616 debugger shows).
All multi-byte values are little endian.

The device only ever sends in answer to a command, and never more than the
command asked for. That is the flow control: the BL616 bridge passes about
80 kB/s and loses bytes when more than about 10 kB arrive in one go, so a
host reads memory in chunks of at most 2048 words and waits for each.

## Commands

| op | name | arguments | answer |
|---|---|---|---|
| `00` | NOP | | |
| `01` | RESET | | |
| `02` | ID | | 16 bytes |
| `03` | WREG | address (1), value (4) | |
| `04` | RREG | address (1) | value (4) |
| `05` | ARM | | |
| `06` | STOP | | |
| `07` | RMEM | word address (3), word count (3) | count × 4 bytes |

To get in step, send eight `00` and a RESET: the longest command has six
argument bytes, so the zeros end whatever was half received (as a write of
zero at worst, which the reset then undoes).

RESET ends a capture, discarding it, and puts every register back to its
default, except CLOCK. ARM starts a capture and is ignored while one runs. STOP ends a
running capture now, keeping what is in memory.

RMEM addresses wrap at M, the end of the ring. Any byte sent during a readout
ends it after the word being sent (the byte itself is then dropped). Don't
send RMEM while a capture runs.

While the device is sending an answer it does not listen: bytes sent to it
then are dropped. Wait for each answer before the next command.

### ID

| byte | |
|---|---|
| 0-3 | `OXLA` |
| 4 | protocol version, 1 |
| 5 | capabilities: bit 0 RLE, bit 1 two samples per clock, bit 2 the channels are an ADC, bit 3 the clock can be changed (register `08`) |
| 6 | channels, W: 8, 14 or 16 |
| 7 | samples per clock, P: 1 or 2 |
| 8-11 | capture clock in Hz, as it is now |
| 12-15 | length of the memory ring in words, M: 2,097,152, or 2,097,151 with 14 channels |

The highest sample rate is clock × P. The others are clock / (n + 1). With
three clocks to choose from that is 81, 108 and 135 MHz and their
fractions.

## Registers

Written with WREG. Unused bits are ignored.

| address | name | default | |
|---|---|---|---|
| `00` | DIV | 0 | 24 bits. One sample every DIV + 1 clocks |
| `01` | POST_WORDS | 0 | 22 bits. Words written after the word with the trigger sample |
| `02` | PRE_WORDS | 0 | 22 bits. The trigger is not looked for until this many words are written |
| `03` | POST_SAMPLES | `ffffffff` | Samples taken after the trigger sample; `ffffffff` for no limit |
| `04` | FLAGS | 0 | bit 0 RLE, bit 1 two samples per clock (only with DIV = 0), bit 2 test pattern |
| `05` | CHMASK | all ones | Channels not set read as 0 |
| `06` | TMODE | 0 | See below |
| `07` | TCOUNT | 0 | 16 bits. The trigger is the (TCOUNT + 1)th event |
| `08` | CLOCK | 1 | The capture clock: 0 is 81 MHz, 1 is 108, 2 is 135. See below |
| `10`-`14` | A | 0 | Term A: MASK, VALUE, RISE, FALL, EDGE |
| `18`-`1c` | B | 0 | Term B, the same |

Read with RREG. STATUS can be read at any time, and is how a host waits for
a capture; the others are valid once it says done:

| address | name | |
|---|---|---|
| `80` | STATUS | bit 0 running, 1 triggered, 2 done, 3 overflow, 4 SDRAM ready; bits 13:8 the number of real bits in the last word, 0 to 32 |
| `81` | TRIG | bits 20:0 the address of the word with the trigger sample; bits 25:24 which of the samples that start in that word (raw mode) |
| `82` | STOP | bits 20:0 the address after the last word written |
| `83` | COUNT | words written, up to M where it stays |

The test pattern replaces the samples with a counter that goes up by one per
sample, from 0 at ARM. The trigger sees it too, so a host can check memory,
triggers and RLE with nothing connected. CHMASK does not apply to it.

## Changing the clock

A write to CLOCK retunes the PLL behind the capture logic. The link to the
host has a clock of its own and stays up, and the other registers keep
their values, but a capture in progress and whatever was in memory are
lost, and the SDRAM is initialized again, which takes a few milliseconds.
So: write CLOCK, read STATUS until bit 4 (SDRAM ready) is set, give it up
after a second or two, then read the ID again for the clock in Hz.

There are three settings, 0 to 2; the ID does not say so. A write of 3
selects 108 MHz. CLOCK keeps its value through RESET, until it is written
again or the FPGA is reconfigured, when it is 108 MHz. A write of the value
it already has does all of the above too.

Registers must not be written while a capture runs; they are read by the
capture logic as they are.

## Trigger

A term is a condition per channel: a channel set in MASK must equal its bit
in VALUE, one set in RISE must be 1 after 0, in FALL 0 after 1, in EDGE
different from the sample before. The term matches a sample when all its
conditions hold. A term with nothing set matches every sample. The first
sample of a capture has no sample before it and matches no edge.

| TMODE | event |
|---|---|
| 0 | every sample: the capture triggers at once |
| 1 | A |
| 2 | B |
| 3 | A or B |
| 4 | A and B on the same sample |
| 5 | A, then B on a later sample |
| 6 | B, then A on a later sample |

With TCOUNT the event must happen TCOUNT + 1 times; for 5 and 6 the whole
sequence starts over after each.

## A capture

Memory is a ring of M words, written from address 0 at ARM for as long as
the capture runs. The capture ends when

- POST_WORDS words have been written after the word that holds the trigger
  sample, or
- POST_SAMPLES samples have been taken after the trigger sample: the word in
  progress is written and is the last, or
- STOP: the same, except that the last word may have no real bits at all
  (STATUS bits 13:8 are 0), in raw mode and in RLE mode alike, when nothing
  was waiting to be written; drop it, or
- the FIFO in front of the memory overflowed (STATUS bit 3). The data up to
  there is good and the trigger position may not be.

Then the last `min(COUNT, wanted)` words before STOP, read in ascending
order, are the capture in time order, and TRIG is somewhere among them when
STATUS says triggered.

Raw mode (FLAGS bit 0 clear): the samples are a stream of bits, W per
sample, the earliest sample and the lowest bit first, cut into 32 bit words.
With 8 or 16 channels that is 4 or 2 whole samples per word. With 14, a
sample can straddle two words, and 16 samples fill 7 words exactly; M is a
multiple of 7 so that a word's address says where the samples in it start:
the first sample that starts in the word at address a starts at bit
(W - 32a mod W) mod W. The last word may be partly filled; STATUS bits 13:8
say how many of its bits are real.

RLE mode: a word is the sample in the low W bits and a count above it; the
sample was seen count + 1 times in a row. The trigger sample always starts a
new word, the one at TRIG. Only with one sample per clock. A capture is then
bounded in samples by POST_SAMPLES and in memory by POST_WORDS; set
PRE_WORDS for the history wanted, in words.

The memory takes a little under one word per clock. Raw captures of 16
channels at one sample per clock, or 8 channels at two, need half a word per
clock; 14 channels at two need seven eighths. RLE needs up to one word per sample, so on signals that change with
nearly every sample it overflows at the full clock rate and is safe from half
of it down.
