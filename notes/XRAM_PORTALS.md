# XRAM Portals — Reference for Emulator Implementation

Everything you need to understand and implement Milestone 1.4 (XRAM Portals) in the RP6502 emulator.

**Sources:**
- Picocomputer docs: https://picocomputer.github.io/ria.html (UART, XRAM sections)
- Local: `picocomputer.github.io/docs/source/ria.rst`
- Firmware: `rp6502/src/ria/sys/ria.c`, `rp6502/src/ria/sys/mem.h`
- CC65: `cc65/include/rp6502.h`
- Examples: `examples/src/mode3.c`, `examples/src/raspberry.c`

---

## 1. Why XRAM Exists — The Memory Problem

The W65C02S can address exactly 64 KB ($0000–$FFFF). On the RP6502 that address space is nearly full:

| Range       | What's there |
|------------|--------------|
| $0000–$FEFF | System RAM (64 KB chip, but top 256 bytes cut off) |
| $FF00–$FFCF | Reserved / not system RAM (208 bytes) |
| $FFD0–$FFDF | VIA (16 bytes) |
| $FFE0–$FFFF | RIA registers (32 bytes) |

The 6502 is left with **~65,280 bytes** of usable RAM. A bitmap framebuffer at 320×240×8bpp = 76,800 bytes. That's bigger than the entire address space. There's no room for graphics data, audio tables, sprite images, etc.

**The solution:** The Pico (RIA) has its own 520 KB of fast SRAM — completely separate from the 6502's address space. The RIA dedicates 64 KB of this as **XRAM** (Extended RAM). The 6502 can't see it directly; it accesses it through **portals**: single-byte registers at known addresses that act as a "window" into XRAM.

That SRAM is on the **RP2350** (Raspberry Pi Pico 2), the microcontroller that runs the RIA firmware. The 6502 is a separate chip on the board; it talks to the Pico over the bus. The RIA firmware reserves 64 KB of the RP2350's SRAM as XRAM and exposes it to the 6502 only through the portal registers ($FFE4–$FFEB), so the 6502 gets extra space for framebuffers, audio, sprites, etc., without that data living in its own 64 KB address space.

---

## 2. XRAM Portal Registers ($FFE4–$FFEB)

```
$FFE4  RW0    — portal 0 data: read = xram[ADDR0], write = xram[ADDR0] = val
$FFE5  STEP0  — signed 8-bit: added to ADDR0 after every RW0 access
$FFE6  ADDR0  — low byte of XRAM address for portal 0
$FFE7         — high byte of XRAM address for portal 0

$FFE8  RW1    — portal 1 data (same as RW0 but independent)
$FFE9  STEP1  — signed 8-bit step for portal 1
$FFEA  ADDR1  — low byte of XRAM address for portal 1
$FFEB         — high byte of XRAM address for portal 1
```

ADDR0 and ADDR1 are 16-bit little-endian values spanning two consecutive register bytes ($FFE6–$FFE7 and $FFEA–$FFEB).

**In plain terms:**

- **XRAM** is a separate 64 KB RAM that lives on the RP2350; the 6502 cannot address it directly. The only way in or out is through these 8 bytes of registers — the "portals."

- **Portal 0** (registers $FFE4–$FFE7): You set **ADDR0** (low byte at $FFE6, high byte at $FFE7) to the XRAM address you care about. You set **STEP0** ($FFE5) to how much that address should change after each access (usually +1). Then:
  - **Read $FFE4 (RW0):** the 6502 gets the byte at `xram[ADDR0]`; then the hardware does `ADDR0 += STEP0`.
  - **Write $FFE4 (RW0):** the 6502 stores a byte into `xram[ADDR0]`; then `ADDR0 += STEP0` again.
  So one read or write both transfers one byte and moves the "cursor" (ADDR0) by STEP0. No need to manually update the address in code for sequential access.

- **Portal 1** ($FFE8–$FFEB) does the same thing with **ADDR1** and **STEP1**, independently. So you can have two cursors into XRAM (e.g. one source, one destination) and copy or process data without buffering in 6502 RAM.

- **Why "portal":** The 6502 only sees single-byte registers at $FFE4–$FFEB. Behind the scenes, the RIA uses ADDR0/ADDR1 to index into its 64 KB XRAM buffer and uses STEP0/STEP1 to advance after each access. So the 6502 is "looking through" a one-byte window that moves through XRAM.

---

## 3. How a Portal Works — The Core Mechanic

Both portals work identically. Using portal 0 as example:

**Before use:** set ADDR0 and STEP0.

**Read from XRAM:**
```
LDA $FFE4   ; A = xram[ADDR0], then ADDR0 += STEP0
```

**Write to XRAM:**
```
STA $FFE4   ; xram[ADDR0] = A, then ADDR0 += STEP0
```

**Auto-step:** After every read or write to RW0, ADDR0 is automatically incremented by STEP0. This is what makes sequential access fast — no explicit address bookkeeping needed.

**STEP is signed:** It's an `int8_t`, so valid values are -128 to +127. Common uses:
- `+1` — forward sequential (most common, default after reset)
- `-1` — reverse traversal
- `0` — repeat-same-address (e.g. write the same value to a region by combining with a loop)
- `+width` — skip by row (e.g. drawing a vertical line in a bitmap)

**Example — write 100 bytes of value $FF starting at XRAM address $2000:**
```asm
LDA #$00     ; ADDR0 lo = $00
STA $FFE6
LDA #$20     ; ADDR0 hi = $20
STA $FFE7
LDA #$01     ; STEP0 = 1
STA $FFE5
LDA #$FF
LDX #100
loop:
STA $FFE4    ; write to xram[ADDR0], auto-advance
DEX
BNE loop
```

**Line by line:**
- **LDA #$00 / STA $FFE6** — Put $00 in the low byte of ADDR0. Together with the next two lines, ADDR0 will be $2000 (little-endian: low=$00, high=$20).
- **LDA #$20 / STA $FFE7** — Put $20 in the high byte of ADDR0. ADDR0 is now $2000, so the portal points at the first byte we want to write in XRAM.
- **LDA #$01 / STA $FFE5** — Set STEP0 to 1. After each write to RW0, ADDR0 will advance by one byte.
- **LDA #$FF** — Load the value we want to write ($FF) into A. We'll store it 100 times.
- **LDX #100** — X is the loop counter: we'll write 100 bytes.
- **loop: STA $FFE4** — Write A to RW0. The RIA stores $FF at xram[ADDR0], then does ADDR0 += 1 (so next time we write to the next byte).
- **DEX** — Decrement X (100 → 99 → … → 0).
- **BNE loop** — If X ≠ 0, branch back to `loop`. After 100 iterations, X is 0 and we fall through; we've written 100 bytes of $FF to XRAM at $2000–$2063.

---

## 4. Two Portals — Why?

From the docs: *"Having only one portal would make moving XRAM very slow since data would have to buffer in 6502 RAM."*

With two portals, you can copy within XRAM without using 6502 RAM as a temp buffer:
```asm
; Copy 256 bytes from XRAM $1000 → XRAM $2000
; Portal 0 = source, Portal 1 = destination
; Set ADDR0=$1000, STEP0=1, ADDR1=$2000, STEP1=1
LDX #0
loop:
LDA $FFE4    ; read from source (ADDR0 auto-increments)
STA $FFE8    ; write to dest   (ADDR1 auto-increments)
DEX
BNE loop     ; 256 iterations
```

This is also how graphics routines update VGA framebuffers, and how OS file I/O (`read_xram`, `write_xram`) moves data.

---

## 5. The Hardware Implementation in `ria.c`

The key loop in `rp6502/src/ria/sys/ria.c`:

```c
// Every iteration (every 6502 clock cycle):
RIA_RW0 = xram[RIA_ADDR0];   // pre-load RW0 register with current xram value
RIA_RW1 = xram[RIA_ADDR1];   // pre-load RW1 register with current xram value
```

This is a tight PIO-driven loop on the Pico's second core. Before checking for any event, the firmware **continuously refreshes** `regs[RW0]` and `regs[RW1]` from the current XRAM address. That means reads are always available instantly — no latency.

Then on a bus event:

```c
case CASE_WRITE(0xFFE4): // W XRAM0
    xram[RIA_ADDR0] = data;
    // (also notifies PIX bus — ignore in emulator)
    __attribute__((fallthrough));
case CASE_READ(0xFFE4):  // R XRAM0
    RIA_ADDR0 += RIA_STEP0;   // post-increment (same path for read AND write)
    break;
```

Note `fallthrough` — both read and write cases do the auto-step. The `CASE_READ` macro is just `addr & 0x1F` — it's the address of the register being read on the bus. The `CASE_WRITE` is `0x20 | (addr & 0x1F)` — write detected on the bus.

From `mem.h`:
```c
#define REGS(addr)  regs[(addr) & 0x1F]       // index into 32-byte register array
#define REGSW(addr) ((uint16_t *)&REGS(addr))[0]  // 16-bit little-endian access
```

```c
#define RIA_STEP0  *(int8_t *)&REGS(0xFFE5)   // signed cast!
#define RIA_ADDR0  REGSW(0xFFE6)               // 16-bit: lo=$FFE6, hi=$FFE7
```

The signed cast on STEP is the critical detail — it's stored as a byte but read as `int8_t` so that -1 (stored as `0xFF`) actually subtracts 1 from ADDR.

---

## 6. Default State After Reset

From the docs:
> *"STEP0 and STEP1 default to 1 after reset."*

So if a 6502 program never sets STEP, sequential writes just work. The emulator should initialize `regs[STEP0] = 1` and `regs[STEP1] = 1` as part of the reset sequence.

---

## 7. What the Emulator Does NOT Need (Yet)

The firmware's `CASE_WRITE(0xFFE4)` does two extra things beyond the simple `xram[ADDR0] = data`:

```c
PIX_SEND_XRAM(RIA_ADDR0, data);         // broadcast to VGA over PIX bus
if (xram_queue_page == REGS(0xFFEB))    // notify audio engine if relevant page
    ...
```

Both are **Phase 2 (VGA) concerns**. The emulator doesn't need either. The emulator just needs the simple logic:
- write → `xram[addr] = val`, then `addr += step`
- read → return `xram[addr]`, then `addr += step`

---

## 8. Real Usage from Examples

From `examples/src/mode3.c` — clear a framebuffer:

```c
void clear()
{
    unsigned i;
    RIA.addr0 = 0;
    RIA.step0 = 1;
    for (i = 0; i < 61440u / 8; i++)
    {
        RIA.rw0 = 0;
        RIA.rw0 = 0;
        // ... 8 writes per loop, each auto-increments ADDR0
    }
}
```

From `examples/src/raspberry.c` — copy sprite image data into XRAM:

```c
    RIA.addr0 = 0;
    RIA.step0 = 1;
    for (u = 0; u < sizeof(raspberry_128x128); u++)
        RIA.rw0 = raspberry_128x128[u];
```

From `rp6502.h` — the `xram0_struct_set` macro for random-access writes (sets ADDR0 each time, then writes one value):

```c
#define xram0_struct_set(addr, type, member, val)                  \
    RIA.addr0 = (unsigned)(&((type *)0)->member) + (unsigned)addr; \
    switch (sizeof(((type *)0)->member))                           \
    {                                                              \
    case 1:                                                        \
        RIA.rw0 = val;                                             \
        break;                                                     \
    ...
```

---

## 9. Summary — What the Emulator Needs to Do

| Register access | Action |
|-----------------|--------|
| Read $FFE4 (RW0) | return `xram[addr0]`; then `addr0 = addr0 + step0` (signed) |
| Write $FFE4 (RW0) | `xram[addr0] = val`; then `addr0 = addr0 + step0` (signed) |
| Read $FFE8 (RW1) | same with addr1/step1 |
| Write $FFE8 (RW1) | same with addr1/step1 |
| Read/Write $FFE5 (STEP0) | just read/write the byte |
| Read/Write $FFE6–7 (ADDR0) | 16-bit little-endian read/write |
| Read/Write $FFE9 (STEP1) | same as STEP0 |
| Read/Write $FFEA–B (ADDR1) | same as ADDR0 |

Zig specifics:
- **XRAM** = `var xram: [65536]u8 = undefined;` in `ria.zig`
- **STEP** needs to be read as `i8` then added to a `u16` address: `addr0 = addr0 +% @bitCast(u16, @as(i16, @bitCast(i8, step0)))` — wrapping addition, address wraps around at $FFFF → $0000 (same behavior as the Pico)
- **ADDR0/ADDR1** are 16-bit values but exposed as two separate bytes — reading $FFE6 returns lo, $FFE7 returns hi; writing works the same way
- Initialize `step0 = 1` and `step1 = 1` on reset
- Expand `bus.zig` to route $FFE4–$FFEB (portal registers) to `ria.zig` instead of falling through to RAM.
