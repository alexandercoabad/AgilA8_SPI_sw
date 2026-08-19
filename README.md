![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# AgilA8 - an 8-bit Microcontroller
Agila is Tagalog for "eagle" - specifically evoking the Philippine Eagle (Haribon), the country's national bird. AgilA8 pairs that with A8, the name of the CPU core at the center of the design: Agil + A8 = AgilA8, the two overlapping on a shared capital A.

## Layout 
<img width="471" height="643" alt="Screenshot 2026-08-19 at 6 35 25 AM" src="https://github.com/user-attachments/assets/311f9214-8b5d-435b-8a26-f53cb2e36b4e" />

3D Viewer: https://gds-viewer.tinytapeout.com/?model=https://alexandercoabad.github.io/AgilA8/tinytapeout.oas&pdk=sky130A


## How it works

AgilA8 is a compact 8-bit microcontroller built around A8, a custom
16-instruction CPU (see `docs/ISA.md`), with memory-mapped GPIO, a 16-bit
timer, and PWM generation.

Both instruction and data memory live off-chip on the Tiny Tapeout QSPI
Pmod. Program code is fetched from external SPI flash (CS0) using a
standard `03h` Read Data command; data memory lives on one of the
Pmod's two PSRAM chips (RAM A / CS1) using standard `02h`/`03h`
Write/Read commands. This keeps the on-chip design small enough to fit
a 1x2 tile budget - Tiny Tapeout's own RAM32 macro is *half* the size of
this design's DMEM and needs 3x2 tiles on its own, so a plain on-chip
flip-flop array was never going to fit. Only plain, single-line SPI
commands are used for flash/PSRAM - deliberately not flash's
continuous-read mode or PSRAM's QPI mode, both of which need a
mode-byte/setup sequence that's easy to get subtly wrong without
hardware to verify against.

A third front-end, a general-purpose SPI master intended for driving an
external device (an LCD, an ADC, another MCU), shares the same physical
lines using CS2. **On the stock QSPI Pmod, CS2 ("RAM B") is wired
directly to a second, populated PSRAM chip**, not out to any external
connector pin - so this peripheral needs one of two fixes before it can
reach anything external. See "RAM A/B mode select" below for both, and
which one this design actually implements in hardware today.

All three front-ends (flash, PSRAM, and the general-purpose SPI
controller) are driven by one shared SPI shift engine rather than three
separate FSMs, since they're never active at the same time (see below)
and consolidating saves real area - roughly 85 flip-flops for the
shared engine plus three thin front-ends, versus about 196 flip-flops
for three independent controllers.

Because `imem_valid` and `dmem_valid` are never asserted in the same
cycle (fetch and memory-access are separate, sequential states in the
core's FSM), and the DMEM-side peripherals are mutually exclusive by
address decode, the shared engine can grant flash/PSRAM/SPI with a
simple fixed-priority mux rather than needing real bus arbitration -
by construction, at most one of the three is ever requesting at once.

### RAM A/B mode select

The general-purpose SPI controller's CS2 conflict with the Pmod's
second PSRAM chip has two real fixes:

1. **Cut the CS2 trace on the Pmod's PCB** (documented directly in the
   Pmod's own repo, [mole99/qspi-pmod](https://github.com/mole99/qspi-pmod)):
   permanently disables that PSRAM chip, frees the pin for the SPI
   controller. Simple, but irreversible on that specific board - RAM B
   is gone for good once cut.
2. **An external SPDT switch, wired to both CS2 itself and to `ui_in[7]`**
   - what this design actually implements. One pole of the switch
   routes the Pmod's CS2 pad to *either* the RAM B chip *or* an external
   device header pin; the other pole (moving with the same physical
   throw) feeds `ui_in[7]`, so the RTL always knows which position the
   switch is in. This is reversible - flip the switch, get the other
   mode - at the cost of losing one general-purpose GPIO input bit and
   a small amount of extra logic to sample it.

`ui_in[7]` is sampled exactly once, ~15 clock cycles after `rst_n`
releases (long enough for a freshly-flipped mechanical switch, or a pin
still settling out of reset, to be trustworthy), latched into a
**STRAP** register, and held constant for the rest of that power-on
session - it is not a live, continuously-read mode switch. The result
is exposed read-only at `STRAP` (`0xF5`, see address map below).

- **STRAP = 0 (default):** CS1 carries RAM A traffic normally; CS2
  carries the general-purpose SPI controller's traffic - only correct
  if the switch's other pole is *also* thrown to connect CS2 to the
  external device header at the same time, not to RAM B.
- **STRAP = 1 (RAM-B mode):** *all* DMEM PSRAM traffic reroutes from
  CS1 to CS2 instead - RAM A is completely unused in this mode, and
  DMEM is backed by the RAM B chip instead. The general-purpose SPI
  controller is disabled: any firmware write to `SPI_DATA` in this mode
  completes immediately as a safe no-op (`SPI_READY` still pulses, so
  nothing hangs) rather than ever driving CS2 with SPI command bytes
  while real RAM-B traffic also needs that same pin - which would
  otherwise corrupt live DMEM contents.

Because `ui_in[7]` is also one of the 8 bits GPIO_IN normally exposes,
dedicating it to this strap isn't a one-time cost - it permanently
shrinks general-purpose GPIO input from 8 usable bits to 7. `GPIO_IN`
bit 7 will simply always read back the same value as `STRAP`.

**Important:** the two poles of the switch have to physically agree -
nothing in this design can detect or correct a switch wired backwards
(CS2 pointing at RAM B while `ui_in[7]` reads 0, or vice versa). Get
that wrong and RAM-B-mode DMEM traffic would go out to nothing (CS1
silent, CS2 not actually connected to RAM B), or default-mode SPI
traffic would corrupt live RAM B contents instead of reaching an
external device - verify the wiring matches before relying on either
mode.

### Address map

| Address range            | Device                                                          |
| ------------------------ | ------------------------------------------------------------------|
| 0x00 - 0xEF, 0xF6 - 0xF7 | RAM (external PSRAM - RAM A in default mode, RAM B in STRAP=1 mode) |
| 0xF0 - 0xF2              | GPIO                                                             |
| 0xF3 - 0xF4              | SPI (general-purpose - default mode only, see "RAM A/B mode select") |
| 0xF5                     | STRAP (R) - RAM A/B mode select readback, see above              |
| 0xF8 - 0xFB              | Timer                                                            |
| 0xFC - 0xFD              | PWM                                                              |

> **Note:** `0xF3`/`0xF4` used to be plain RAM in earlier revisions of
> this design; `0xF5` was too, until the STRAP register claimed it.
> Any program that stored ordinary data at those three addresses will
> now silently hit the SPI controller or STRAP instead of RAM.

Instructions are fetched separately, as two consecutive bytes from
external flash (big-endian: high byte at PC, low byte at PC+1) - flash
isn't part of the 8-bit DMEM address space above.

### IO

| # | Input       | Output       | Bidirectional                    |
| - | ----------- | ------------ | --------------------------------- |
| 0 | GPIO in 0   | GPIO out 0   | Flash CS (CS0)                    |
| 1 | GPIO in 1   | GPIO out 1   | SD0 - MOSI (shared flash/PSRAM)   |
| 2 | GPIO in 2   | GPIO out 2   | SD1 - MISO (shared flash/PSRAM)   |
| 3 | GPIO in 3   | GPIO out 3   | SCK (shared flash/PSRAM)          |
| 4 | GPIO in 4   | GPIO out 4   | SD2 (held high, unused)           |
| 5 | GPIO in 5   | GPIO out 5   | SD3 (held high, unused)           |
| 6 | GPIO in 6   | GPIO out 6   | RAM A CS (CS1) - unused in STRAP=1 mode |
| 7 | GPIO in 7 (also feeds STRAP, see above) | PWM output | RAM B CS / general SPI CS (CS2) - which one depends on STRAP |


#### GPIO

| Register | Address     | Description                                                      |
| -------- | ----------- | ------------------------------------------------------------------ |
| GPIO_OUT | 0xF0 (R/W)  | Write sets `uo_out[6:0]`; read returns the last value written    |
| GPIO_IN  | 0xF1 (R)    | Reads the current state of `ui_in[7:0]`. **Bit 7 is shared with the STRAP sample** - see "RAM A/B mode select" above; it always reads the same value as `STRAP`, not an independent signal |
| GPIO_DIR | 0xF2 (R/W)  | Read/write register; not wired to anything (`ui_in`/`uo_out` are fixed-direction TT pins, so there's no direction to control) |

`uo_out[7]` is dedicated to the PWM output, not GPIO - a write of
`0xAA` to GPIO_OUT reads back as `0xAA` internally, but only
`uo_out[6:0]` (`0x2A` in that example) reaches a physical pin.

#### SPI (general-purpose) - default mode only

This peripheral's register interface (`SPI_DATA`/`SPI_CTRL` below) is
correct SPI-master logic, but it only reaches an external device when
**STRAP reads 0** (default mode) - see "RAM A/B mode select" above for
what that depends on and what happens in the other mode. If you'd
rather not deal with the switch/strap mechanism at all, cutting the
Pmod's CS2 trace (also described above) is a simpler, permanent
alternative that makes default mode the *only* mode, with no strap
logic or GPIO_IN cost.

| Register | Address     | Description                                                        |
| -------- | ----------- | -------------------------------------------------------------------- |
| SPI_DATA | 0xF3 (R/W)  | Write: shifts the byte out (CS auto-asserted for the transfer, **blocking** until the 8-bit transfer physically completes). In RAM-B mode (STRAP=1), completes immediately as a safe no-op instead - see above. Read: returns the byte simultaneously shifted in from MISO during the most recent transfer, without starting a new one - to read a byte from a slave, write a dummy `0x00` and then read DATA back (standard full-duplex SPI) |
| SPI_CTRL | 0xF4 (R/W)  | Bits[1:0] = SCK clock divider: `00` = fastest (~sys_clk/2, matches flash/PSRAM speed), `01` = ~sys_clk/8, `10` = ~sys_clk/32, `11` = ~sys_clk/128 (**reset default** - start slow, let software speed up once the attached device's timing is known to tolerate it) |

Mode 0 (CPOL=0, CPHA=0), MSB-first, full-duplex.

Each `SPI_DATA` write is deliberately blocking rather than
fire-and-forget: the core has no instruction cache, so the very next
instruction fetch also needs this same shared bus. Blocking keeps this
peripheral's transfers inside the same single-active-transaction
invariant the shared engine already depends on for flash/PSRAM, with no
separate arbitration hardware needed. CS is likewise auto-pulsed per
byte (asserted only during the active transfer) rather than held low
across a logical multi-byte burst - genuinely continuous bursts aren't
possible on this hardware anyway, since unrelated flash-fetch traffic
would otherwise appear on the shared lines mid-burst; auto-pulsing at
least keeps CS deasserted while that happens, so the attached device
correctly ignores it.

#### Timer

| Register    | Address     | Description                                                    |
| ----------- | ----------- | ---------------------------------------------------------------- |
| TIMER_LO    | 0xF8 (R)    | Bits 7:0 of the free-running 16-bit counter                    |
| TIMER_HI    | 0xF9 (R)    | Bits 15:8 of the counter                                       |
| TIMER_CTRL  | 0xFA (R/W)  | Bit 0 = enable (counts up once per clock while set). Writing bit 1 = 1 resets the counter to 0 |
| TIMER_FLAG  | 0xFB (R/W)  | Bit 0 = overflow (set when the counter wraps past 0xFFFF); any write clears it |

#### PWM

| Register  | Address     | Description                                                        |
| --------- | ----------- | ---------------------------------------------------------------------- |
| PWM_DUTY  | 0xFC (R/W)  | 8-bit duty cycle out of a free-running 256-cycle period. `0xFF` is a special-cased always-on |
| PWM_CTRL  | 0xFD (R/W)  | Bit 0 = enable. Output is forced low whenever disabled, regardless of PWM_DUTY |

## How to test

1. Decide which mode you need (see "RAM A/B mode select" above) and
   make sure the switch/strap wiring (or the CS2 trace cut, if using
   that fix instead) matches before relying on either RAM B or the SPI
   controller.
2. Program the test image onto the Pmod's flash chip and leave the
   PSRAM chip's contents as-is; the program initializes any RAM it
   depends on.
3. Reset the design (`rst_n` low then high) - if using the switch,
   make sure it's in its final position *before* releasing reset, so
   the STRAP sample settles on the intended value.
4. Run the clock. The CPU fetches from flash and reads/writes RAM over
   the shared SPI bus automatically - no host intervention needed once
   running.

This repository has a `test/` directory, but I haven't independently
verified its current contents match every detail described in this
README (in particular, whether it exercises both STRAP modes, not just
default mode) - worth checking directly rather than assuming from this
doc alone.

Before committing to a tapeout, the QSPI Pmod flash-read timing margin
(`read_delay_cfg`, now handled centrally in `qspi_shared_engine.v`) is
worth validating on real hardware first, since interconnect delay isn't
visible in behavioral simulation - see the FPGA bring-up guide for the
Tiny Tapeout FPGA Development Kit + QSPI Pmod path used for that.

## External hardware

- [Tiny Tapeout QSPI Pmod](https://store.tinytapeout.com/products/QSPI-Pmod-p716541602),
  plugged into the demoboard's bidirectional Pmod header. Flash (program
  memory) is used as designed regardless of mode.
- An external SPDT switch (see "RAM A/B mode select" above), wired so
  one pole routes the Pmod's CS2 pad between the onboard RAM B chip and
  an external device header pin, and the other pole feeds `ui_in[7]` so
  the RTL can tell which position it's in. Get the two poles wired
  backwards relative to each other and neither mode works correctly -
  double check against "RAM A/B mode select" above before trusting
  either one.
- Alternatively, permanently cut the Pmod's CS2 trace (see above) if
  you only ever want the SPI controller and don't need RAM B or the
  switch/strap mechanism at all.
- Without either fix in place, drive an external SPI device over the
  separate `ui_in`/`uo_out` GPIO header instead, bit-banging the
  protocol in software - that header is independent of the QSPI Pmod's
  `uio` bus and works regardless of STRAP.
- Tiny Tapeout demoboard, or the
  [FPGA Development Kit](https://store.tinytapeout.com/products/FPGA-Development-Kit-p813805747)
  for pre-tapeout bring-up on real silicon-adjacent hardware.


# Acknowledgments & Attribution

This file documents the open-source tools, process design kit, and prior
art that AgilA8 depends on or was inspired by. It's split into two
categories that are easy to conflate but legally distinct:

1. **Tools and IP actually incorporated into this design** - their
   licenses (all Apache-2.0) place real obligations on redistribution.
2. **Architectural inspiration from prior projects** - no code was
   copied from these; crediting them is good academic/community
   practice, not a license requirement, since taking inspiration from
   a *design pattern* (as opposed to copying source text) isn't a
   copyright event.

---

## 1. Tools & IP incorporated into this design (Apache-2.0)

The physical chip (GDS) produced from this repository directly embeds
standard-cell layouts from, and was built using, the following
Apache-2.0-licensed projects. Their copyright notices are reproduced
below per Apache-2.0 §4; none of them ship a separate `NOTICE` file as
of this writing (checked: skywater-pdk's repository root contains only
`LICENSE` and `AUTHORS`, no `NOTICE` - worth re-checking the others
listed here yourself before a formal release, since this wasn't
exhaustively verified for every entry).

### SkyWater SKY130 PDK
The standard-cell library this design was synthesized and hardened
against.

```
Copyright 2020 SkyWater PDK Authors
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```
Source: https://github.com/google/skywater-pdk

### open_pdks
PDK build/installer tooling used to assemble the sky130 PDK for the
hardening flow.

Source: https://github.com/fossi-foundation/open-pdks (Apache-2.0)

### OpenLane / OpenROAD
The RTL-to-GDS tool flow (synthesis, place & route, STA, DRC/LVS) that
produced this design's GDS.

```
OpenLane is ©2020-2024 Efabless Corporation and is available under
the Apache License, version 2.0.
```
Source: https://github.com/The-OpenROAD-Project/OpenLane

If citing academically:
> M. Shalan and T. Edwards, "Building OpenLANE: A 130nm OpenROAD-based
> Tapeout-Proven Flow," 2020 IEEE/ACM International Conference on
> Computer-Aided Design (ICCAD), San Diego, CA, USA, 2020, pp. 1-6.

### Tiny Tapeout project templates / tt-support-tools
The `tt_um_*` port convention, `info.yaml` schema, and CI/build
scaffolding this repo's structure follows.

Source: https://github.com/TinyTapeout (templates are Apache-2.0 by
default per Tiny Tapeout's own FAQ)

---

## 2. Architectural inspiration (no code reused)

AgilA8's central design decision - CPU with no on-chip memory,
program fetched from external QSPI flash, working data in external
QSPI PSRAM, sharing physical SPI wires between them via separate chip
selects - follows the same strategic pattern pioneered on Tiny Tapeout
by the following projects. **No RTL, ISA encoding, or source code from
either project was copied** - AgilA8's CPU core, instruction set, and
peripheral RTL were independently designed and implemented. What's
credited here is the *architectural pattern*, not any specific
implementation of it.

### TinyQV (Michael Bell)
First (and to date, most complete) demonstration of this
flash+PSRAM-over-shared-QSPI-Pmod pattern on Tiny Tapeout, including
the specific convention of a single active chip-select and
code-execution-restricted-to-flash.

Source: https://github.com/MichaelBell/tinyQV (Apache-2.0)

### KianV (Hirosh Dabui / splinedrive)
Independent, earlier demonstration of the same external-memory-over-QSPI
pattern (both the uLinux and bare-metal editions), predating this
project.

Source: https://github.com/splinedrive/kianRiscV,
https://github.com/TinyTapeout/KianV-RV32IMA-RISC-V-uLinux-SoC
(check the repository's own LICENSE file directly before citing a
specific license - it wasn't confirmed via an explicit license badge
at the time this was written)

### RISC-V (conceptual influence only)
A8's `r0`-hardwired-to-zero convention and load/store architectural
style are modeled on RISC-V's design philosophy. RISC-V is an open,
freely usable ISA specification; no code is reused here, so this
carries no license obligation. **A8 is not RISC-V-compliant** - it's a
custom 16-bit-instruction, 8-bit-datapath ISA in the RISC-V style, and
should not be described as a RISC-V implementation or use the RISC-V
trademark/logo.

---

## 3. What's original to this project

- The A8 instruction encoding (16-bit fixed-width, R-type/I-type
  split, the specific opcode table) is a custom design, not derived
  from any existing ISA's bit layout.
- All RTL in this repository (`a8_core.v`, `a8_alu.v`,
  `a8_regfile.v`, `a8_peripherals.v`, `qspi_shared_engine.v`,
  `spi_ctrl.v`, `tt_um_agila8.v`) was independently written for
  this project. `qspi_shared_engine.v` consolidates what were
  previously three separate controllers (`qspi_flash_reader.v` for
  flash, `qspi_psram_ctrl.v` for PSRAM, and `spi_ctrl.v` for the
  general-purpose SPI peripheral) into one shared engine, and now also
  implements the STRAP-driven RAM A/B mode select described above -
  see that file's header for why, and `spi_ctrl.v`'s own
  header/testbench for the general-purpose SPI register semantics it
  still documents even though it isn't the module instantiated in the
  final design.
- The verification suite, bug fixes, and STA signoff analysis
  documented in this repository's history are this project's own work.

---

## Unverified claims to double-check before formal publication

- A code comment (originally in `qspi_flash_reader.v`, which may or may
  not still be present in the repo as reference material - it isn't
  part of the module actually instantiated after the merge) attributes
  a ~20ns round-trip timing margin figure to "TinyQV's own QSPI
  controller comments." This has not been independently confirmed
  against TinyQV's actual source - verify both the exact figure/its
  origin, and which file it currently lives in, before citing it as a
  TinyQV-derived fact.
- The Apache-2.0 NOTICE-file check above was only performed for
  skywater-pdk; confirm the other three Apache-2.0 entries (open_pdks,
  OpenLane, Tiny Tapeout templates) don't ship their own NOTICE files
  before finalizing this document, since if any of them do, its
  contents would need to be reproduced here per §4(d).
- This README's "How to test" section notes a `test/` directory exists
  in the repo, but its exact contents (and whether it covers both STRAP
  modes) weren't independently confirmed while writing this update -
  GitHub blocked automated access to list that directory's files
  directly.
