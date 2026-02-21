// RIA (RP6502 Interface Adapter) register emulation.
// UART registers only for Phase 1: READY ($FFE0), TX ($FFE1), RX ($FFE2).
// See: https://picocomputer.github.io/ria.html

const std = @import("std");

// UART register addresses (RIA at $FFE0–$FFFF)
pub const ADDR_READY: u16 = 0xFFE0; // bit 7 = TX not full, bit 6 = RX has data
pub const ADDR_TX: u16 = 0xFFE1;
pub const ADDR_RX: u16 = 0xFFE2;

const READY_TX_BIT: u8 = 0x80; // bit 7: OK to send
const READY_RX_BIT: u8 = 0x40; // bit 6: RX has data

// Larger than RIA firmware (32) so we don't drop stdin when 6502 polls slowly; power-of-2 for cheap modulo.
const RX_BUF_SIZE: usize = 256;

// Module-level state (bus callbacks are C-callable, no context pointer).
var rx_buf: [RX_BUF_SIZE]u8 = undefined;
var rx_read: usize = 0;
var rx_write: usize = 0;

/// Read from a RIA UART register. Only $FFE0–$FFE2 are implemented.
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
        else => return 0x00,
    }
}

/// Write to a RIA UART register.
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
        else => {},
    }
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
