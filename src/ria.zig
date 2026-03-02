// RIA (RP6502 Interface Adapter) register emulation.
// UART ($FFE0–$FFE2), XRAM portals ($FFE4–$FFEB)
// See: https://picocomputer.github.io/ria.html

const std = @import("std");

// RIA register addresses ($FFE0–$FFEB implemented)
pub const ADDR_READY: u16 = 0xFFE0; // bit 7 = TX not full, bit 6 = RX has data
pub const ADDR_TX: u16 = 0xFFE1;
pub const ADDR_RX: u16 = 0xFFE2;
pub const ADDR_RW0: u16 = 0xFFE4;
pub const ADDR_STEP0: u16 = 0xFFE5;
pub const ADDR_ADDR0_LO: u16 = 0xFFE6;
pub const ADDR_ADDR0_HI: u16 = 0xFFE7;
pub const ADDR_RW1: u16 = 0xFFE8;
pub const ADDR_STEP1: u16 = 0xFFE9;
pub const ADDR_ADDR1_LO: u16 = 0xFFEA;
pub const ADDR_ADDR1_HI: u16 = 0xFFEB;

const READY_TX_BIT: u8 = 0x80; // bit 7: OK to send
const READY_RX_BIT: u8 = 0x40; // bit 6: RX has data

// Larger than RIA firmware (32) so we don't drop stdin when 6502 polls slowly; power-of-2 for cheap modulo.
const RX_BUF_SIZE: usize = 256;

// Module-level state (bus callbacks are C-callable, no context pointer).
var rx_buf: [RX_BUF_SIZE]u8 = undefined;
var rx_read: usize = 0;
var rx_write: usize = 0;

// XRAM: 64 KB extended RAM (separate from 6502 address space)
var xram: [65536]u8 = undefined;

// XRAM portal state
var addr0: u16 = 0;
var step0: u8 = 1; // default 1 after reset
var addr1: u16 = 0;
var step1: u8 = 1;

/// Add signed step to address (wrapping).
fn addrAddStep(addr: u16, step: u8) u16 {
    const step_i8: i8 = @bitCast(step);
    const delta: i16 = @as(i16, step_i8);
    return @bitCast(@as(i16, @bitCast(addr)) + delta);
}

/// Read from a RIA register. $FFE0–$FFEB implemented.
pub fn readByte(addr: u16) u8 {
    switch (addr) {
        ADDR_READY => {
            var ready: u8 = READY_TX_BIT; // TX always ready (no FIFO backpressure)
            if (rx_read != rx_write) ready |= READY_RX_BIT;
            return ready;
        },
        ADDR_TX => return 0x00, // TX is write-only; read undefined
        ADDR_RX => {
            if (rx_read == rx_write) return 0x00;
            const b = rx_buf[rx_read];
            rx_read = (rx_read + 1) % RX_BUF_SIZE;
            return b;
        },
        ADDR_RW0 => {
            const b = xram[addr0];
            addr0 = addrAddStep(addr0, step0);
            return b;
        },
        ADDR_STEP0 => return step0,
        ADDR_ADDR0_LO => return @truncate(addr0),
        ADDR_ADDR0_HI => return @truncate(addr0 >> 8),
        ADDR_RW1 => {
            const b = xram[addr1];
            addr1 = addrAddStep(addr1, step1);
            return b;
        },
        ADDR_STEP1 => return step1,
        ADDR_ADDR1_LO => return @truncate(addr1),
        ADDR_ADDR1_HI => return @truncate(addr1 >> 8),
        else => return 0x00,
    }
}

/// Write to a RIA register.
pub fn writeByte(addr: u16, val: u8) void {
    switch (addr) {
        ADDR_READY => {}, // read-only
        ADDR_TX => {
            if (!@import("builtin").is_test) {
                const stdout = std.fs.File.stdout();
                stdout.writeAll(&.{val}) catch {};
            }
        },
        ADDR_RX => {}, // read-only
        ADDR_RW0 => {
            xram[addr0] = val;
            addr0 = addrAddStep(addr0, step0);
        },
        ADDR_STEP0 => step0 = val,
        ADDR_ADDR0_LO => addr0 = (addr0 & 0xFF00) | val,
        ADDR_ADDR0_HI => addr0 = (addr0 & 0x00FF) | (@as(u16, val) << 8),
        ADDR_RW1 => {
            xram[addr1] = val;
            addr1 = addrAddStep(addr1, step1);
        },
        ADDR_STEP1 => step1 = val,
        ADDR_ADDR1_LO => addr1 = (addr1 & 0xFF00) | val,
        ADDR_ADDR1_HI => addr1 = (addr1 & 0x00FF) | (@as(u16, val) << 8),
        else => {},
    }
}

/// Reset XRAM portal state (call on CPU reset).
pub fn resetXramPortals() void {
    addr0 = 0;
    step0 = 1;
    addr1 = 0;
    step1 = 1;
}

/// Push a byte into the RX buffer (for tests or injection). Drops if full.
pub fn pushRx(byte: u8) void {
    const next = (rx_write + 1) % RX_BUF_SIZE;
    if (next == rx_read) return; // full, drop
    rx_buf[rx_write] = byte;
    rx_write = next;
}

/// Poll stdin (non-blocking) and push any available bytes into the RX buffer.
/// Call from the main emulator loop. On Windows, no-op (stdin polling TBD).
pub fn pollStdin() void {
    if (@import("builtin").os.tag == .windows) return;
    const posix = std.posix;
    const stdin_fd = std.fs.File.stdin().handle;
    var fds: [1]posix.pollfd = .{.{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 }};
    const n_ready = posix.poll(&fds, 0) catch return;
    if (n_ready == 0) return;
    if (fds[0].revents & posix.POLL.IN == 0) return;
    var read_buf: [1]u8 = undefined;
    const bytes_read = std.fs.File.stdin().read(&read_buf) catch return;
    if (bytes_read > 0) pushRx(read_buf[0]);
}
