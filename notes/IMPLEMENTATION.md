# RP6502 Emulator — Implementation Plan

Learning journey: understand the **RP6502 (Picocomputer)**, the **Raspberry Pi Pico (RP2040/RP2350)**, and **Zig** — by building an emulator.

The RP6502 firmware runs on two Picos (RIA + VGA), so emulating them means understanding how the Pico SDK, PIO, DMA, USB host, and scanvideo work under the hood. This project teaches all three at once.

**What we're building:** A cross-platform emulator for the [Picocomputer RP6502](https://picocomputer.github.io/) in Zig. Host terminal (stdin/stdout) replaces USB serial — develop and test 6502 programs without hardware.

---

## Phase 1: RIA Only (Terminal Mode)

**Goal:** Emulate the system without VGA Pico — 6502 CPU, RAM, XRAM, RIA registers, OS API, monitor shell — accessed through a host terminal.

### 1.1 6502 CPU Core (existing C library)

Use an existing C 6502 library via Zig's C interop — get a working CPU fast, focus learning on the RP6502 side. Rewriting the CPU from scratch in Zig is a separate exercise (see Phase 3).

**Resources:**
- C libraries to evaluate:
  - [bzotto/MCS6502](https://github.com/bzotto/MCS6502) — simple, callback-based (`ReadByte`/`WriteByte`), easy to integrate
  - [redcode/6502](https://github.com/redcode/6502) — ANSI C, portable, GPL-3
  - [floooh/chips](https://github.com/floooh/chips) — header-only C, 6502 + other chips, MIT
- 6502 instruction set: http://www.6502.org/tutorials/6502opcodes.html
- Zig C interop: Context7 `/websites/ziglang_master`

**Zig learning:** `@cImport`, C interop, build system (`addCSourceFile`), linking C code

**Tasks:**
- [ ] Evaluate C 6502 libraries (callback API, 65C02 support, license)
- [ ] Pick one and add it to the project (vendor the C source or use Zig package)
- [ ] Wire it into `build.zig` (`addCSourceFile` or `addCSourceFiles`)
- [ ] Create `src/cpu.zig` wrapper: thin Zig API around the C library
- [ ] Define `readByte(addr)` / `writeByte(addr, val)` callbacks that the C lib calls
- [ ] Back with flat 64 KB RAM array for now
- [ ] Verify 65C02 extensions work (W65C02S uses: STZ, BRA, PHX/PHY/PLX/PLY, TRB, TSB)
- [ ] Write tests: execute hand-assembled programs (`LDA #$42; STA $00; BRK`)
- [ ] Pass a 6502 functional test suite

### 1.2 Memory Bus (Address Decoding)

**Resources:**
- Memory map: https://picocomputer.github.io/ria.html
- CC65 memory layout: https://cc65.github.io/doc/rp6502.html

**Zig learning:** `switch`, enums, modules/files

**Tasks:**
- [ ] Create `src/bus.zig` with address decoding
- [ ] Route `$0000–$FEFF` → system RAM (64 KB array)
- [ ] Route `$FF00–$FFCF` → unassigned (return `$00`)
- [ ] Route `$FFD0–$FFDF` → VIA stub (return `$00`, ignore writes)
- [ ] Route `$FFE0–$FFFF` → RIA registers (placeholder, next step)
- [ ] CPU vectors (`$FFFA–$FFFF`) are inside RIA register space
- [ ] Wire CPU's `readByte`/`writeByte` to the bus
- [ ] Test: verify correct routing with reads/writes at boundary addresses

### 1.3 RIA Registers (Data Path)

**Resources:**
- RIA register map: https://picocomputer.github.io/ria.html
- RIA firmware source: `/Users/nenaddjordjevic/CProjects/rp6502/src/ria/`

**Zig learning:** packed structs, bitwise ops, slices

**Tasks:**
- [ ] Create `src/ria.zig` with register file struct
- [ ] Implement UART registers: READY ($FFE0), TX ($FFE1), RX ($FFE2)
- [ ] Implement VSYNC counter ($FFE3) — increment at ~60 Hz
- [ ] Implement XRAM portal 0: RW0 ($FFE4), STEP0 ($FFE5), ADDR0 ($FFE6–7)
- [ ] Implement XRAM portal 1: RW1 ($FFE8), STEP1 ($FFE9), ADDR1 ($FFEA–B)
- [ ] Implement XRAM storage: 64 KB byte array accessed through portals
- [ ] Implement XSTACK ($FFEC): 512-byte push/pop stack
- [ ] Implement ERRNO ($FFED–E): 16-bit OS error code
- [ ] Implement OP ($FFEF): write triggers OS call (placeholder)
- [ ] Implement IRQ register ($FFF0)
- [ ] Implement OS return area: RETURN/$80, BUSY, LDA/$A9, A, LDX/$A2, X, RTS/$60
- [ ] Implement SREG ($FFF8–B): 32-bit extended register
- [ ] Implement vectors: NMI ($FFFA), RESET ($FFFC), IRQ ($FFFE)
- [ ] Test: 6502 program writes to TX → byte appears (stub for now)

### 1.4 Console I/O (Host Terminal)

**Zig learning:** `std.posix`, raw terminal mode, non-blocking I/O

**Tasks:**
- [ ] Put host terminal into raw mode (no echo, no line buffering)
- [ ] Wire TX ($FFE1) write → emit byte to stdout
- [ ] Wire RX ($FFE2) read → consume byte from stdin
- [ ] Wire READY ($FFE0) bits: bit 7 = TX ready, bit 6 = RX has data
- [ ] Implement non-blocking stdin polling
- [ ] Restore terminal mode on exit (cleanup)
- [ ] Test: 6502 program that echoes typed characters

### 1.5 RESET and Boot Sequence

**Resources:**
- Boot process: `/Users/nenaddjordjevic/CProjects/rp6502/src/ria/main.c`
- .rp6502 file format: https://picocomputer.github.io/os.html

**Zig learning:** file I/O, command-line args, error handling

**Tasks:**
- [ ] Parse command-line args (ROM file path, drive directory)
- [ ] Load a .rp6502 ROM file into RAM
- [ ] Support raw binary loading as alternative
- [ ] Set RESET vector ($FFFC–$FFFD) to entry point
- [ ] Implement reset sequence: hold CPU → load → release
- [ ] Test: load and run a simple ROM from disk

### 1.6 OS Call Mechanism

**Resources:**
- OS ABI: https://picocomputer.github.io/os.html
- Firmware: `/Users/nenaddjordjevic/CProjects/rp6502/src/ria/api/`

**Zig learning:** state machines, tagged unions

**Tasks:**
- [ ] Implement OP ($FFEF) write → dispatch OS call by operation ID
- [ ] Implement BUSY handshake: bit 7 = 1 while processing, BRA offset = $FE (spin)
- [ ] Implement completion: BUSY bit 7 = 0, BRA offset = $00, set A and X return values
- [ ] Understand the self-modifying code trick ($FFF1–$FFF7)
- [ ] Implement basic ops: `zxstack`, `phi2`, `codepage`, `lrand`
- [ ] Implement `stdin_opt`, `clock_gettime`, `clock_settime`
- [ ] Test: 6502 invokes OS call and gets result back

### 1.7 File I/O Operations

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
- [ ] Test: 6502 program opens a file, reads it, prints contents

### 1.8 Directory Operations

**Tasks:**
- [ ] Implement `opendir`
- [ ] Implement `closedir`
- [ ] Implement `readdir`
- [ ] Implement `mkdir`
- [ ] Implement `chdir`, `getcwd`
- [ ] Test: listing files from 6502

### 1.9 Monitor (Command Shell)

**Resources:**
- Monitor source: `/Users/nenaddjordjevic/CProjects/rp6502/src/ria/mon/`

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
- [ ] Monitor runs when no 6502 program is loaded (or after CTRL-ALT-DEL)
- [ ] Test: type `help`, `ls`, `load` and see expected output

### 1.10 Run Real Programs

**Resources:**
- Example programs: `/Users/nenaddjordjevic/CProjects/examples/`

**Tasks:**
- [ ] Load and run hello world / simple text programs
- [ ] Load and run memory test programs
- [ ] Load and run ehbasic
- [ ] Debug and fix issues until real programs work
- [ ] Document any RP6502 behavior discovered during testing

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
