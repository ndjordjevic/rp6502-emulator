# 6502 CPU Core — Reference for Emulator Implementation

Reference for Milestone 1.1: wiring a C 6502 library into Zig via C interop.

**Library selection:** See [C_6502_LIBRARY_EVALUATION.md](C_6502_LIBRARY_EVALUATION.md) for the library comparison and reasoning.

**Sources:**
- vrEmu6502: `vendor/vrEmu6502/vrEmu6502.h`, `vendor/vrEmu6502/vrEmu6502.c`
- Upstream: https://github.com/visrealm/vrEmu6502
- Zig C interop docs: https://ziglang.org/documentation/master/#C
- Klaus Dormann functional tests: https://github.com/Klaus2m5/6502_65C02_functional_tests

---

## 1. Why a C Library (Not a Zig CPU from Scratch)

The RP6502 uses a **W65C02S** — the WDC CMOS variant with extended opcodes (WAI, STP, TRB, TSB, etc.) and correct decimal mode behavior. Writing a cycle-accurate W65C02 from scratch takes substantial effort and testing.

Strategy for Phase 1: use an existing, proven C library via Zig's C interop — get a working CPU immediately and focus on the RP6502-specific parts (RIA, XRAM, OS calls). A Zig CPU rewrite is optional later (Phase 3).

---

## 2. vrEmu6502 — What It Is

**[visrealm/vrEmu6502](https://github.com/visrealm/vrEmu6502)** — Troy Schrapel's 6502 emulator library.

- **MIT license, C99, no dependencies** — trivially vendored
- **CPU models**: `CPU_6502` (NMOS), `CPU_6502U` (NMOS with undocumented), `CPU_65C02`, **`CPU_W65C02`**, `CPU_R65C02`
- **Callback-based bus**: two function pointers passed at create time; no global state
- **Passes Klaus Dormann tests**: 6502 functional, decimal, 65C02 decimal, 65C02 extended, W65C02 extended, R65C02 extended
- **Maintained**: active into 2026, CI on Win/Linux/Pi Pico

---

## 3. vrEmu6502 API

### Create / Destroy

```c
// Create a CPU. model = CPU_W65C02 for RP6502.
VrEmu6502* vrEmu6502New(vrEmu6502Model model,
                         vrEmu6502MemRead readFn,
                         vrEmu6502MemWrite writeFn);

void vrEmu6502Destroy(VrEmu6502* vr6502);
```

### Callback signatures

```c
// Read: called by the CPU for every memory access.
// isDbg = true means the CPU is NOT executing (e.g. disassembly); devices
// should NOT change state when isDbg is true (e.g. XRAM portal must NOT step).
typedef uint8_t (*vrEmu6502MemRead)(uint16_t addr, bool isDbg);

// Write: called by the CPU for every memory write.
typedef void (*vrEmu6502MemWrite)(uint16_t addr, uint8_t val);
```

### Execution

```c
void   vrEmu6502Reset(VrEmu6502* cpu);          // reset; reads PC from $FFFC–$FFFD
void   vrEmu6502Tick(VrEmu6502* cpu);            // one clock cycle
uint8_t vrEmu6502InstCycle(VrEmu6502* cpu);      // one full instruction; returns cycle count
```

### Register getters / setters

```c
uint16_t vrEmu6502GetPC(VrEmu6502*);
void     vrEmu6502SetPC(VrEmu6502*, uint16_t pc);
uint8_t  vrEmu6502GetAcc(VrEmu6502*);
uint8_t  vrEmu6502GetX(VrEmu6502*);
uint8_t  vrEmu6502GetY(VrEmu6502*);
uint8_t  vrEmu6502GetStackPointer(VrEmu6502*);
uint8_t  vrEmu6502GetStatus(VrEmu6502*);  // P register (NV-BDIZC)
```

### Interrupts

```c
vrEmu6502Interrupt *vrEmu6502Int(VrEmu6502*);  // pointer to IRQ line; set to IntRequested/IntCleared
vrEmu6502Interrupt *vrEmu6502Nmi(VrEmu6502*);  // pointer to NMI line
```

---

## 4. How It's Wired — build.zig

The C source is vendored at `vendor/vrEmu6502/`. Two changes in `build.zig`:

```zig
// Tell Zig where to find vrEmu6502.h
exe.root_module.addIncludePath(b.path("vendor/vrEmu6502"));

// Compile vrEmu6502.c and link it in; -DVR_EMU_6502_STATIC = no DLL import/export
exe.root_module.addCSourceFile(.{
    .file = b.path("vendor/vrEmu6502/vrEmu6502.c"),
    .flags = &.{"-DVR_EMU_6502_STATIC"},
});
```

The same two lines are repeated for the test binary.

---

## 5. Zig C Interop

### `@cImport` — importing C headers

```zig
const c = @cImport({
    @cInclude("vrEmu6502.h");
});
// Now c.vrEmu6502New, c.VrEmu6502, c.CPU_W65C02, etc. are all available.
```

### `callconv(.c)` — making Zig functions callable from C

The read/write callbacks must have C calling convention. In Zig:

```zig
pub fn readByte(addr: u16, is_dbg: bool) callconv(.c) u8 { ... }
pub fn writeByte(addr: u16, val: u8) callconv(.c) void { ... }
```

Without `callconv(.c)`, the function pointer types won't match what vrEmu6502 expects and the build will fail.

---

## 6. The cpu.zig Wrapper

`src/cpu.zig` is a thin Zig struct around the C pointer:

```zig
const c = @cImport({ @cInclude("vrEmu6502.h"); });

pub const ReadFn  = *const fn (addr: u16, is_dbg: bool) callconv(.c) u8;
pub const WriteFn = *const fn (addr: u16, val: u8) callconv(.c) void;

pub const Cpu = struct {
    ptr: *c.VrEmu6502,

    pub fn create(read_fn: ReadFn, write_fn: WriteFn) !Cpu {
        const ptr = c.vrEmu6502New(c.CPU_W65C02, read_fn, write_fn);
        if (ptr == null) return error.OutOfMemory;
        return .{ .ptr = ptr.? };
    }

    pub fn destroy(self: *Cpu) void { c.vrEmu6502Destroy(self.ptr); }
    pub fn reset(self: *Cpu) void   { c.vrEmu6502Reset(self.ptr); }
    pub fn instCycle(self: *Cpu) u8 { return c.vrEmu6502InstCycle(self.ptr); }
    pub fn getPC(self: *const Cpu) u16 { return c.vrEmu6502GetPC(self.ptr); }
    // ... getA, getX, getY, getS, getStatus, setPC
};
```

**Usage from main.zig:**

```zig
var c = try cpu.Cpu.create(bus.readByte, bus.writeByte);
defer c.destroy();
c.reset();

// Run one instruction at a time
while (c.getPC() != halt_addr) {
    _ = c.instCycle();
}
```

---

## 7. The W65C02S — What Makes It Different

The RP6502 uses the **W65C02S**, the WDC CMOS variant of the 65C02. Important differences from the base 6502:

| Feature | NMOS 6502 | 65C02 | W65C02S |
|---------|-----------|-------|---------|
| BRA (branch always) | ✗ | ✓ | ✓ |
| STZ (store zero) | ✗ | ✓ | ✓ |
| PHX/PHY/PLX/PLY | ✗ | ✓ | ✓ |
| TRB/TSB | ✗ | ✓ | ✓ |
| (IND) indirect zero page | ✗ | ✓ | ✓ |
| WAI (wait for interrupt) | ✗ | ✗ | ✓ |
| STP (stop clock) | ✗ | ✗ | ✓ |
| Correct decimal mode flags | ✗ | varies | ✓ |
| Read-modify-write fixes | ✗ | ✓ | ✓ |

The `CPU_W65C02` model in vrEmu6502 emulates all of these correctly.

---

## 8. Reset Behavior

After `vrEmu6502Reset()`:
- PC is loaded from vectors $FFFC (lo) and $FFFD (hi)
- D (decimal) flag is cleared
- I (interrupt disable) flag is set
- SP = $FD
- A, X, Y are undefined

So before calling `c.reset()`, the emulator must have the correct reset vector written to RAM at $FFFC–$FFFD.

---

## 9. isDbg — Why It Matters

The `readByte(addr, is_dbg)` callback receives `is_dbg = true` when the library reads memory for non-execution purposes (e.g. a built-in disassembler). **Devices with side-effecting reads must not change state when `is_dbg` is true.** Example: reading XRAM portal RW0 normally steps ADDR0 — but if `is_dbg` is true it should not. The emulator's current bus passes `_ = is_dbg` (ignores it), which is fine as long as no debug-only reads are triggered.

---

## 10. Tick vs instCycle

- `vrEmu6502Tick(cpu)` — one clock cycle. 6502 instructions take 2–7 cycles. Use for cycle-accurate timing.
- `vrEmu6502InstCycle(cpu)` — one complete instruction (runs all cycles internally), returns cycle count. Use for correctness without cycle-per-cycle overhead.

The emulator uses `instCycle` in the main loop — simpler, and fine for Phase 1 terminal-mode.
