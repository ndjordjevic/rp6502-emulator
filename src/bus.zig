// Memory bus with address decoding for RP6502.
// Routes CPU read/write requests to RAM, VIA, or RIA per the memory map.
// See: https://picocomputer.github.io/ria.html

const memory = @import("memory.zig");
const ria = @import("ria.zig");

// Address ranges (RP6502 memory map)
const RAM_END: u16 = 0xFEFF; // $0000–$FEFF: system RAM
const UNASSIGNED_START: u16 = 0xFF00; // $FF00–$FFCF: unassigned
const UNASSIGNED_END: u16 = 0xFFCF;
const VIA_START: u16 = 0xFFD0; // $FFD0–$FFDF: VIA (W65C22S)
const VIA_END: u16 = 0xFFDF;
const RIA_START: u16 = 0xFFE0; // $FFE0–$FFFF: RIA registers (includes vectors $FFFA–$FFFF)
const RIA_UART_END: u16 = 0xFFE2; // $FFE0–$FFE2: UART (READY, TX, RX)

/// Read callback for vrEmu6502: (address, is_debug_read) -> byte. C-callable.
pub fn readByte(addr: u16, is_dbg: bool) callconv(.c) u8 {
    _ = is_dbg;
    if (addr <= RAM_END) {
        return memory.ram[addr];
    }
    if (addr >= UNASSIGNED_START and addr <= UNASSIGNED_END) {
        return 0x00; // unassigned
    }
    if (addr >= VIA_START and addr <= VIA_END) {
        return 0x00; // VIA stub
    }
    if (addr >= RIA_START and addr <= RIA_UART_END) {
        return ria.readByte(addr);
    }
    // $FFE3–$FFFF: rest of RIA (VSYNC, XRAM, vectors, etc.) — use RAM for vectors
    return memory.ram[addr];
}

/// Write callback for vrEmu6502: (address, value) -> void. C-callable.
pub fn writeByte(addr: u16, val: u8) callconv(.c) void {
    if (addr <= RAM_END) {
        memory.ram[addr] = val;
        return;
    }
    if (addr >= UNASSIGNED_START and addr <= UNASSIGNED_END) return;
    if (addr >= VIA_START and addr <= VIA_END) return;
    if (addr >= RIA_START and addr <= RIA_UART_END) {
        ria.writeByte(addr, val);
        return;
    }
    if (addr >= RIA_START) {
        memory.ram[addr] = val;
    }
}
