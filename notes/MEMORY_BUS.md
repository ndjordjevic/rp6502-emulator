# Memory Bus — Reference for Emulator Implementation

Reference for Milestone 1.2: address decoding for the RP6502 memory map.

**Sources:**
- Picocomputer RIA docs: https://picocomputer.github.io/ria.html
- Local: `picocomputer.github.io/docs/source/ria.rst`
- CC65 memory layout: https://cc65.github.io/doc/rp6502.html
- Emulator: `src/bus.zig`, `src/memory.zig`

---

## 1. The 6502 Address Space

The W65C02S has a 16-bit address bus — it can address exactly **64 KB** ($0000–$FFFF). Every memory read and write the CPU makes goes through the two callbacks registered at create time:

```zig
readByte(addr: u16, is_dbg: bool) callconv(.c) u8
writeByte(addr: u16, val: u8) callconv(.c) void
```

The **bus** is just address-decoding logic: given an address, route the read or write to the correct device.

---

## 2. RP6502 Memory Map

```
$0000–$FEFF  System RAM        65,280 bytes (64 KB chip; top 256 bytes reserved)
$FF00–$FFCF  Unassigned        return $00 on read; ignore writes
$FFD0–$FFDF  VIA (W65C22S)     I/O port, timers, etc.
$FFE0–$FFFF  RIA registers     32 bytes; includes 6502 vectors ($FFFA–$FFFF)
```

**Key details:**

- The system RAM chip is 128 KB (AS6C1008), but only 64 KB is mapped into the 6502's address space. The upper 64 KB is used by the VGA Pico and other hardware — the 6502 never sees it directly.
- The 256-byte hole $FF00–$FFCF is not wired to anything. Reads return bus float / $00.
- $FFD0–$FFDF is the W65C22S VIA (I/O chip) — GPIO, timers, shift register.
- $FFE0–$FFFF is the RIA (Pico 2 W running RIA firmware). This includes:
  - $FFE0–$FFEB: UART + VSYNC + XRAM portals
  - $FFEC–$FFF9: XSTACK, OP, OS call mechanism
  - $FFFA–$FFFF: 6502 interrupt vectors (NMI, RESET, IRQ) — these live inside RIA register space, not RAM

---

## 3. 6502 Vectors ($FFFA–$FFFF)

The 6502 reads three 16-bit vectors from fixed addresses on reset and interrupts:

| Address   | Vector | Triggered by |
|-----------|--------|--------------|
| $FFFA–$FFFB | NMI  | Non-maskable interrupt (falling edge on NMI pin) |
| $FFFC–$FFFD | RESET | Power-on or RESB pin goes low→high |
| $FFFE–$FFFF | IRQ/BRK | Maskable interrupt or BRK instruction |

These addresses are inside RIA register space ($FFE0–$FFFF). On the real hardware, the RIA Pico manages these; in the emulator, they fall through to the RAM array (addresses $FFFA–$FFFF in `memory.ram[]`). The emulator writes the desired start address into `memory.ram[0xFFFC]` / `memory.ram[0xFFFD]` before calling `cpu.reset()`.

---

## 4. How bus.zig Implements It

The bus decodes the address and routes to the appropriate handler:

```
Read:
  addr <= $FEFF  → memory.ram[addr]
  $FF00–$FFCF   → return $00 (unassigned)
  $FFD0–$FFDF   → return $00 (VIA stub)
  $FFE0–$FFEB   → ria.readByte(addr)   (UART + VSYNC + XRAM portals)
  $FFEC–$FFFF   → memory.ram[addr]     (OS call regs + vectors)

Write:
  addr <= $FEFF  → memory.ram[addr] = val
  $FF00–$FFCF   → no-op
  $FFD0–$FFDF   → no-op (VIA stub)
  $FFE0–$FFEB   → ria.writeByte(addr, val)
  $FFEC–$FFFF   → memory.ram[addr] = val  (OS call regs + vectors)
```

The `RIA_XRAM_END` boundary ($FFEB) is significant: below it, reads/writes go to `ria.zig` (with side effects — XRAM stepping, etc.); above it, they go to RAM (used by the OS call mechanism in milestone 1.5 and vectors in 1.6).

---

## 5. Why memory.zig is a Separate Module

`memory.zig` holds the flat 64 KB RAM array:

```zig
pub var ram: [65536]u8 = std.mem.zeroes([65536]u8);
```

It's separate from `bus.zig` so that:
1. Tests can pre-load RAM directly (`memory.ram[0xFFFC] = lo;`) without going through the bus
2. The bus, RIA, and main can all import `memory` independently
3. The module boundary is clean: `bus` = routing logic; `memory` = storage

---

## 6. VIA Stub

The W65C22S VIA ($FFD0–$FFDF) is at U5 on the PCB. It provides two 8-bit I/O ports, two 16-bit timers, a shift register, and interrupt logic.

For Phase 1 (terminal only), the VIA is stubbed:
- All reads return $00
- All writes are ignored

No real RP6502 programs depend on VIA in terminal mode. The VIA becomes important when testing keyboard GPIO or timing circuits — that's hardware testing, not Phase 1.

---

## 7. The Unassigned Region ($FF00–$FFCF)

This gap between RAM and VIA is not wired. The CC65 linker keeps code and data out of this range. Reads return $00 (bus float behavior). Writes are no-ops.

---

## 8. Address Decoding Boundaries — Quick Reference

| Range | Boundary constants in bus.zig | Handler |
|-------|-------------------------------|---------|
| $0000–$FEFF | `RAM_END = 0xFEFF` | `memory.ram[]` |
| $FF00–$FFCF | `UNASSIGNED_START/END` | return $00 / no-op |
| $FFD0–$FFDF | `VIA_START/END` | stub |
| $FFE0–$FFEB | `RIA_START`, `RIA_XRAM_END = 0xFFEB` | `ria.readByte/writeByte` |
| $FFEC–$FFFF | (no named constant) | `memory.ram[]` |

---

## 9. Testing the Bus

From `tests.zig`, the bus address decoding is verified with direct boundary checks:

```zig
// RAM boundaries
bus.readByte(0x0000, false)  // → memory.ram[0]
bus.readByte(0xFEFF, false)  // → memory.ram[0xFEFF]

// Unassigned: read $00, write no-op
bus.readByte(0xFF00, false)  // → $00
bus.writeByte(0xFF50, 0xBB)  // no-op; bus.readByte(0xFF50) still → $00

// VIA stub
bus.readByte(0xFFD0, false)  // → $00

// RIA UART
bus.readByte(0xFFE0, false)  // → $80 (READY: TX ready, no RX)

// Vectors fall through to RAM
memory.ram[0xFFFC] = 0x34;
bus.readByte(0xFFFC, false)  // → $34
```

---

## 10. Evolution of the Bus Routing (Milestones)

The RIA boundary has grown as milestones completed:

| After milestone | RIA range handled by ria.zig |
|----------------|------------------------------|
| 1.2 (initial)  | $FFE0–$FFE2 (UART only)      |
| 1.3 Echo       | $FFE0–$FFE2 (UART)           |
| 1.4 XRAM       | $FFE0–$FFEB (+ VSYNC + XRAM) |
| 1.5 OS calls   | $FFE0–$FFF9 (full RIA)       |
