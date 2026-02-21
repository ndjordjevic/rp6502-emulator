# RP6502 Emulator — Implementation Plan

Learning journey: understand the **RP6502 (Picocomputer)**, the **Raspberry Pi Pico (RP2040/RP2350)**, and **Zig** — by building an emulator.

The RP6502 firmware runs on two Picos (RIA + VGA), so emulating them means understanding how the Pico SDK, PIO, DMA, USB host, and scanvideo work under the hood. This project teaches all three at once.

**What we're building:** A cross-platform emulator for the [Picocomputer RP6502](https://picocomputer.github.io/) in Zig. Host terminal (stdin/stdout) replaces USB serial — develop and test 6502 programs without hardware.

---

## Strategy: Emulator-Driven Learning

The emulator is the **primary learning vehicle** for the RP6502. Each milestone follows the same loop:

1. **Study** — Read the relevant firmware source and documentation
2. **Implement** — Build the feature in the emulator
3. **Test** — Validate with a 6502 program (proves understanding)

This naturally covers Learning Plan phases 4–8 (chip interactions, RIA firmware, VGA firmware, OS API, advanced topics). The Learning Plan (`rp6502-learning/notes/LEARNING_PLAN.md`) serves as the **reference checklist** of topics to understand; the emulator milestones here are **how you learn them**.

**Two parallel tracks:**
- **Track A: Emulator** (primary) — study firmware, implement, test. No hardware needed.
- **Track B: Hardware** (at the bench) — assemble remaining ICs, load RIA firmware, probe with logic analyzer, compare emulator vs real hardware. Runs whenever you're ready.

### Milestone → Learning Plan mapping

| Emulator Milestone | Learning Plan Topics Covered |
|---|---|
| 1.1 CPU Core | Phase 1.1 (W65C02S overview) |
| 1.2 Memory Bus | Phase 4.1 (6502 bus), Phase 4.3 (memory map) |
| 1.3 Echo Terminal | Phase 5.2 (UART registers) |
| 1.4 XRAM Portals | Phase 4.3 (XRAM), Phase 5.2 (XRAM access) |
| 1.5 OS Call Mechanism | Phase 5.2 (OS call registers), Phase 7.1 (OS API) |
| 1.6 ROM Loading & Reset | Phase 5.1 (RIA initialization), Phase 7.1 (ABI) |
| 1.7 File I/O | Phase 5.3 (Storage), Phase 7.1 (File I/O calls) |
| 1.8 Monitor Shell | Phase 5.3 (Monitor) |
| 1.9 Run Real Programs | Phase 7.2 (6502 software development) |
| Phase 2: VGA | Phase 6 (VGA firmware), Phase 7.3 (video programming) |
| Phase 2: Audio | Phase 8.3 (Audio systems) |

---

## Phase 1: RIA Only (Terminal Mode)

**Goal:** Emulate the system without VGA Pico — 6502 CPU, RAM, XRAM, RIA registers, OS API, monitor shell — accessed through a host terminal.

### 1.1 6502 CPU Core (existing C library)

Use an existing C 6502 library via Zig's C interop — get a working CPU fast, focus learning on the RP6502 side. Rewriting the CPU from scratch in Zig is a separate exercise (see Phase 3).

**Resources:**
- 6502 instruction set: http://www.6502.org/tutorials/6502opcodes.html
- 65C02 Assembly (Wikibooks): https://en.wikibooks.org/wiki/65c02_Assembly
- 6502 must-read books: http://www.6502.org/books
- Klaus Dormann / Klaus2m5 functional tests: https://github.com/Klaus2m5/6502_65C02_functional_tests
- Zig C interop: Context7 `/websites/ziglang_master`

**C 6502 library evaluation (deep research):** See **[C 6502 library evaluation](notes/C_6502_LIBRARY_EVALUATION.md)** for a detailed comparison. **Recommendation: use [visrealm/vrEmu6502](https://github.com/visrealm/vrEmu6502)** — MIT, C99, callback API, full W65C02 support, passes all Klaus tests including W65C02 extended opcodes, actively maintained (commits into 2026), no dependencies.

**Zig learning:** `@cImport`, C interop, build system (`addCSourceFile`), linking C code

**Tasks:**
- [✔] Evaluate C 6502 libraries (callback API, 65C02 support, license) — see [C_6502_LIBRARY_EVALUATION.md](notes/C_6502_LIBRARY_EVALUATION.md)
- [✔] Pick one and add it to the project (vendor the C source or use Zig package) — vrEmu6502 vendored in `vendor/vrEmu6502/`, wired in `build.zig`
- [✔] Wire it into `build.zig` (`addCSourceFile` or `addCSourceFiles`)
- [✔] Create `src/cpu.zig` wrapper: thin Zig API around the C library
- [✔] Define `readByte(addr)` / `writeByte(addr, val)` callbacks that the C lib calls
- [✔] Back with flat 64 KB RAM array for now
- [✔] Write tests: execute hand-assembled programs (`LDA #$42; STA $00; BRK`)
- [✔] Pass a 6502 functional test suite

### 1.2 Memory Bus (Address Decoding)

**Resources:**
- Memory map: https://picocomputer.github.io/ria.html
- CC65 memory layout: https://cc65.github.io/doc/rp6502.html

**Zig learning:** `switch`, enums, modules/files

**Tasks:**
- [✔] Create `src/bus.zig` with address decoding
- [✔] Route `$0000–$FEFF` → system RAM (64 KB array)
- [✔] Route `$FF00–$FFCF` → unassigned (return `$00`)
- [✔] Route `$FFD0–$FFDF` → VIA stub (return `$00`, ignore writes)
- [✔] Route `$FFE0–$FFFF` → RIA registers (placeholder, next step)
- [✔] CPU vectors (`$FFFA–$FFFF`) are inside RIA register space
- [✔] Wire CPU's `readByte`/`writeByte` to the bus
- [✔] Test: verify correct routing with reads/writes at boundary addresses

### 1.3 Echo Terminal (Milestone 1) ← current

**Study first:**
- `rp6502/src/ria/sys/com.h`, `com.c` — UART config, TX/RX circular buffers, stdio driver
- `rp6502/src/ria/sys/ria.c` — CASE_READ/WRITE for $FFE0–$FFE2
- Picocomputer docs: https://picocomputer.github.io/ria.html (UART section)
- Reference: `notes/UART_EMULATOR_REFERENCE.md`
- Learning plan: Phase 5.2 (UART registers)

**Zig learning:** `std.posix`, raw terminal mode, non-blocking I/O

**Tasks:**
- [✔] Create `src/ria.zig` with register file (UART)
- [✔] Implement UART registers: READY ($FFE0), TX ($FFE1), RX ($FFE2)
- [✔] Wire TX ($FFE1) write → emit byte to stdout
- [✔] Wire RX ($FFE2) read → consume byte from stdin buffer
- [✔] Wire READY ($FFE0) bits: bit 7 = TX ready, bit 6 = RX has data
- [✔] Implement non-blocking stdin polling (poll with timeout 0 on Unix; Windows TBD)
- [✔] Test: 6502 program writes to TX → byte appears ("Hi" demo)
- [✔] Put host terminal into raw mode (no echo, no line buffering)
- [✔] Restore terminal mode on exit (cleanup)
- [✔] Test: 6502 echo program — type a key, see it printed (BIT $FFE0, LDA $FFE2, STA $FFE1 loop)

**Done when:** You can run a 6502 echo program — type a key, see it printed — in the host terminal.

### 1.4 XRAM Portals (Milestone 2)

**Study first:**
- `rp6502/src/ria/sys/ria.c` — CASE_READ/WRITE for $FFE4 and $FFE8, xram array, STEP/ADDR logic
- `rp6502/src/ria/sys/mem.h` — REGS/REGSW macros, register layout
- Picocomputer docs: https://picocomputer.github.io/ria.html (XRAM section)
- Learning plan: Phase 4.3 (Memory System), Phase 5.2 (XRAM access)

**Zig learning:** slices, signed/unsigned step arithmetic

**Tasks:**
- [ ] Add 64 KB XRAM array
- [ ] Implement portal 0: RW0 ($FFE4), STEP0 ($FFE5), ADDR0 ($FFE6–7) — read/write XRAM[ADDR0], auto-increment ADDR0 by STEP0
- [ ] Implement portal 1: RW1 ($FFE8), STEP1 ($FFE9), ADDR1 ($FFEA–B)
- [ ] Expand `bus.zig` to route $FFE3–$FFEB to `ria.zig` (currently only $FFE0–$FFE2)
- [ ] Test: 6502 sets ADDR0, writes bytes via RW0, reads them back

**Done when:** 6502 can store and retrieve data in XRAM through both portals with auto-stepping.

### 1.5 OS Call Mechanism (Milestone 3)

**Study first:**
- `rp6502/src/ria/sys/ria.c` — action loop, CASE_WRITE($FFEF), BUSY handshake, self-modifying code at $FFF0–$FFF7
- `rp6502/src/ria/api/api.c` — OS call dispatch table
- OS ABI docs: https://picocomputer.github.io/os.html
- Learning plan: Phase 5.2 (OS call registers), Phase 7.1 (OS API)

**Zig learning:** state machines, tagged unions, enum dispatch

**Tasks:**
- [ ] Implement XSTACK ($FFEC): 512-byte push/pop stack
- [ ] Implement ERRNO ($FFED–E): 16-bit OS error code
- [ ] Implement OP ($FFEF): write triggers OS call by operation ID
- [ ] Implement BUSY handshake ($FFF1): bit 7 = 1 while processing, BRA offset = $FE (spin)
- [ ] Implement completion: BUSY bit 7 = 0, BRA offset = $00, set A and X return values
- [ ] Understand and implement the self-modifying code trick ($FFF0–$FFF7: LDA #A, LDX #X, RTS)
- [ ] Implement IRQ register ($FFF0)
- [ ] Implement SREG ($FFF8–B): 32-bit extended register
- [ ] Implement VSYNC counter ($FFE3): increment at ~60 Hz
- [ ] Implement basic ops: `zxstack` (0x00), `phi2` (0x01), `codepage` (0x02), `lrand` (0x03)
- [ ] Implement `stdin_opt`, `clock_gettime`, `clock_settime`
- [ ] Expand `bus.zig` to route $FFEC–$FFF9 to `ria.zig`
- [ ] Test: 6502 invokes `zxstack` and `lrand`, gets result back

**Done when:** 6502 can call OS operations via OP write, spin on BUSY, and receive return values.

### 1.6 ROM Loading & Reset (Milestone 4)

**Study first:**
- `rp6502/src/ria/mon/rom.c` — ROM loader, .rp6502 file format parsing
- `rp6502/src/ria/main.c` — boot sequence, reset flow
- .rp6502 format: https://picocomputer.github.io/os.html
- Learning plan: Phase 5.1 (RIA initialization)

**Zig learning:** file I/O, command-line args (`std.process.args`), error handling

**Tasks:**
- [ ] Parse command-line args (ROM file path, drive directory)
- [ ] Load .rp6502 ROM file into RAM (parse header, load segments)
- [ ] Support raw binary loading as alternative
- [ ] Set RESET vector ($FFFC–$FFFD) to entry point from ROM
- [ ] Implement reset sequence: hold CPU → load → release
- [ ] Test: load and run a simple compiled program from disk

**Done when:** `zig build run -- hello.rp6502` loads and runs a compiled program.

### 1.7 File I/O (Milestone 5)

**Study first:**
- `rp6502/src/ria/api/osfil.c` — file operation implementations
- `rp6502/src/ria/api/osdir.c` — directory operation implementations
- `rp6502/src/ria/usb/msc.c` — USB mass storage (what the emulator replaces with host filesystem)
- OS docs: https://picocomputer.github.io/os.html (file I/O calls)
- Learning plan: Phase 5.3 (Storage), Phase 7.1 (File I/O)

**Zig learning:** `std.fs`, error unions, allocators

**Tasks:**
- [ ] Map a host directory as the "USB drive"
- [ ] Implement `open` (with XSTACK filename)
- [ ] Implement `close`
- [ ] Implement `read_xstack`, `read_xram`
- [ ] Implement `write_xstack`, `write_xram`
- [ ] Implement `lseek`
- [ ] Implement `unlink`, `rename`
- [ ] Implement `fstat`
- [ ] Implement `opendir`, `closedir`, `readdir`
- [ ] Implement `mkdir`, `chdir`, `getcwd`
- [ ] Test: 6502 program opens a file, reads it, prints contents

**Done when:** 6502 programs can read/write files and list directories on the host filesystem.

### 1.8 Monitor Shell (Milestone 6)

**Study first:**
- `rp6502/src/ria/mon/mon.c` — monitor main loop, command parser
- `rp6502/src/ria/mon/rom.c` — ROM loading commands
- `rp6502/src/ria/mon/ram.c` — memory read/write commands
- Learning plan: Phase 5.3 (Monitor)

**Tasks:**
- [ ] Implement command parser (input line → command + args)
- [ ] Implement `help` — print command list
- [ ] Implement `status` — show system info (PHI2, memory, etc.)
- [ ] Implement `ls` / `dir` — list files
- [ ] Implement `cd` — change directory
- [ ] Implement `load` — load and run a ROM
- [ ] Implement `set phi2` — configure clock speed
- [ ] Implement memory read/write (`0000` to read, `0000:FF` to write)
- [ ] Implement `reboot`, `reset`
- [ ] Monitor runs when no 6502 program is loaded (or after break)
- [ ] Test: type `help`, `ls`, `load hello.rp6502` and see expected output

**Done when:** The emulator boots into a monitor prompt, you can list files, load and run programs.

### 1.9 Run Real Programs (Milestone 7)

**Study first:**
- Example programs: `/Users/nenaddjordjevic/CProjects/examples/src/`
- ehBASIC: `/Users/nenaddjordjevic/CProjects/ehbasic/`
- Learning plan: Phase 7.2 (6502 software development)

**Tasks:**
- [ ] Load and run hello world / simple text programs
- [ ] Load and run memory test programs
- [ ] Load and run ehBASIC
- [ ] Debug and fix issues until real programs work
- [ ] Compare behavior against real hardware (if assembled)
- [ ] Document any RP6502 behavior discovered during testing

**Done when:** ehBASIC runs in the emulator and you can type BASIC programs.

---

## Phase 2: VGA (Later)

**Goal:** Emulate the VGA Pico — pixel modes, text canvas, sprites, audio. Draw to a window on the host.

- [ ] Research Zig graphics libraries (SDL2 bindings, or Zig native)
- [ ] Implement PIX register writes (xreg for VGA config)
- [ ] Implement text canvas mode
- [ ] Implement bitmap modes (1/2/4/8 bpp)
- [ ] Implement tile modes
- [ ] Implement sprite layer
- [ ] Implement audio (PSG, OPL2)
- [ ] Test with graphical example programs

---

## Phase 3: Rewrite 6502 CPU in Zig (Optional, Learning Exercise)

**Goal:** Replace the C library with a 6502/65C02 core written from scratch in Zig — deep-dive into the 6502 instruction set.

- [ ] Create `src/cpu_zig.zig` with a `Cpu` struct (A, X, Y, SP, PC, status flags)
- [ ] Implement instruction fetch-decode-execute loop
- [ ] Implement addressing modes (immediate, zero page, absolute, indexed, indirect)
- [ ] Implement all 6502 instructions
- [ ] Implement 65C02 extensions (STZ, BRA, PHX, PHY, PLX, PLY, TRB, TSB, (IND))
- [ ] Pass the same functional test suite as the C library
- [ ] Swap it in as a drop-in replacement (same `readByte`/`writeByte` interface)
- [ ] Compare performance vs the C library

---

## Architecture

```
┌──────────────────────────────────────┐
│           Host Terminal              │
│     (stdin/stdout on macOS)          │
└───────────────┬──────────────────────┘
                │
┌───────────────▼──────────────────────┐
│         Console I/O Layer            │
│   (raw terminal, maps to UART regs)  │
└───────────────┬──────────────────────┘
                │
┌───────────────▼──────────────────────┐
│          RIA Emulation               │
│  Registers $FFE0–$FFFF               │
│  XRAM (64 KB), XSTACK (512 B)       │
│  OS API dispatch ($FFEF writes)      │
│  Monitor (command parser)            │
└───────────────┬──────────────────────┘
                │
┌───────────────▼──────────────────────┐
│         Memory Bus                   │
│  $0000–$FEFF: RAM (64 KB)            │
│  $FFD0–$FFDF: VIA (stub)            │
│  $FFE0–$FFFF: → RIA registers       │
└───────────────┬──────────────────────┘
                │
┌───────────────▼──────────────────────┘
│     6502 CPU Core (C library)        │
│  readByte() / writeByte() callbacks  │
└──────────────────────────────────────┘
```

## Design Decisions

- **6502 core** — existing C library via Zig's C interop (Phase 1); rewrite in Zig later (Phase 3).
- **Callback-based bus** — CPU calls `readByte(addr)` / `writeByte(addr, val)`.
- **Host filesystem = USB drive** — a directory on disk = FAT32 drive.
- **Host terminal = serial console** — stdin/stdout in raw mode = USB CDC UART.
