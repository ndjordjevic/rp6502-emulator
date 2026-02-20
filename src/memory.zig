// Flat 64 KB RAM and read/write callbacks for the 6502 C library (no context pointer in C API).

/// Backing storage for CPU memory. Index by 16-bit address (0x0000–0xFFFF).
pub var ram: [0x10000]u8 = [_]u8{0} ** 0x10000;

/// Read callback for vrEmu6502: (address, is_debug_read) -> byte. C-callable.
pub fn readByte(addr: u16, is_dbg: bool) callconv(.c) u8 {
    _ = is_dbg;
    return ram[addr];
}

/// Write callback for vrEmu6502: (address, value) -> void. C-callable.
pub fn writeByte(addr: u16, val: u8) callconv(.c) void {
    ram[addr] = val;
}
