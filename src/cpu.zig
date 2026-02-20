// Thin Zig API around vendored vrEmu6502 C library (W65C02 for RP6502).

const c = @cImport({
    @cInclude("vrEmu6502.h");
});

/// Memory read callback: (address, is_debug_read) -> byte.
/// is_dbg is true when the CPU is not executing (e.g. disassembly); devices should not change state when true.
pub const ReadFn = *const fn (addr: u16, is_dbg: bool) callconv(.c) u8;
/// Memory write callback: (address, value) -> void.
pub const WriteFn = *const fn (addr: u16, val: u8) callconv(.c) void;

/// W65C02 CPU handle (opaque C pointer inside).
pub const Cpu = struct {
    ptr: *c.VrEmu6502,

    /// Create a W65C02 CPU with the given read/write callbacks. Caller must call destroy() when done.
    pub fn create(read_fn: ReadFn, write_fn: WriteFn) !Cpu {
        const ptr = c.vrEmu6502New(c.CPU_W65C02, read_fn, write_fn);
        if (ptr == null) return error.OutOfMemory;
        return .{ .ptr = ptr.? };
    }

    /// Free the C CPU; do not use this Cpu after calling.
    pub fn destroy(self: *Cpu) void {
        c.vrEmu6502Destroy(self.ptr);
        self.ptr = undefined;
    }

    /// Reset CPU (PC from vector, clear D, set I; 65C02 semantics).
    pub fn reset(self: *Cpu) void {
        c.vrEmu6502Reset(self.ptr);
    }

    /// Run one clock tick (one cycle).
    pub fn tick(self: *Cpu) void {
        c.vrEmu6502Tick(self.ptr);
    }

    /// Run one instruction cycle; returns number of ticks executed (e.g. 2–7).
    pub fn instCycle(self: *Cpu) u8 {
        return c.vrEmu6502InstCycle(self.ptr);
    }

    // ——— Getters (for debugging / tests) ———
    /// Program counter.
    pub fn getPC(self: *const Cpu) u16 {
        return c.vrEmu6502GetPC(self.ptr);
    }
    /// Set program counter.
    pub fn setPC(self: *Cpu, pc: u16) void {
        c.vrEmu6502SetPC(self.ptr, pc);
    }
    /// Accumulator.
    pub fn getA(self: *const Cpu) u8 {
        return c.vrEmu6502GetAcc(self.ptr);
    }
    /// X index register.
    pub fn getX(self: *const Cpu) u8 {
        return c.vrEmu6502GetX(self.ptr);
    }
    /// Y index register.
    pub fn getY(self: *const Cpu) u8 {
        return c.vrEmu6502GetY(self.ptr);
    }
    /// Stack pointer.
    pub fn getS(self: *const Cpu) u8 {
        return c.vrEmu6502GetStackPointer(self.ptr);
    }
    /// Processor status (P) register.
    pub fn getStatus(self: *const Cpu) u8 {
        return c.vrEmu6502GetStatus(self.ptr);
    }
};
