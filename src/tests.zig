// Standalone test module: CPU + memory integration tests.
// Run with: zig build test

const std = @import("std");
const cpu = @import("cpu.zig");
const memory = @import("memory.zig");
const bus = @import("bus.zig");
const ria = @import("ria.zig");

test "LDA #$42; STA $00; BRK" {
    // Reset vector: CPU starts at $0200
    const start: u16 = 0x0200;
    memory.ram[0xFFFC] = @truncate(start);
    memory.ram[0xFFFD] = @intCast(start >> 8);
    // Program: LDA #$42 (A9 42), STA $00 (85 00), BRK (00)
    memory.ram[start] = 0xA9; // LDA imm
    memory.ram[start + 1] = 0x42;
    memory.ram[start + 2] = 0x85; // STA zp
    memory.ram[start + 3] = 0x00;
    memory.ram[start + 4] = 0x00; // BRK

    var c = try cpu.Cpu.create(bus.readByte, bus.writeByte);
    defer c.destroy();
    c.reset();

    // Three instructions: LDA, STA, BRK
    _ = c.instCycle();
    _ = c.instCycle();
    _ = c.instCycle();

    try std.testing.expectEqual(@as(u8, 0x42), memory.ram[0]);
    try std.testing.expectEqual(@as(u8, 0x42), c.getA());
}

test "bus address decoding" {
    // RAM: $0000–$FEFF
    memory.ram[0x0000] = 0x11;
    memory.ram[0xFEFF] = 0x22;
    try std.testing.expectEqual(@as(u8, 0x11), bus.readByte(0x0000, false));
    try std.testing.expectEqual(@as(u8, 0x22), bus.readByte(0xFEFF, false));

    bus.writeByte(0x0100, 0xAA);
    try std.testing.expectEqual(@as(u8, 0xAA), memory.ram[0x0100]);

    // Unassigned: $FF00–$FFCF — read $00, writes ignored
    try std.testing.expectEqual(@as(u8, 0x00), bus.readByte(0xFF00, false));
    try std.testing.expectEqual(@as(u8, 0x00), bus.readByte(0xFFCF, false));
    bus.writeByte(0xFF50, 0xBB); // no-op
    try std.testing.expectEqual(@as(u8, 0x00), bus.readByte(0xFF50, false));

    // VIA stub: $FFD0–$FFDF — read $00, writes ignored
    try std.testing.expectEqual(@as(u8, 0x00), bus.readByte(0xFFD0, false));
    try std.testing.expectEqual(@as(u8, 0x00), bus.readByte(0xFFDF, false));
    bus.writeByte(0xFFD5, 0xCC); // no-op
    try std.testing.expectEqual(@as(u8, 0x00), bus.readByte(0xFFD5, false));

    // RIA UART: $FFE0–$FFE2 — READY (read), TX (write), RX (read)
    try std.testing.expectEqual(@as(u8, 0x80), bus.readByte(0xFFE0, false)); // READY: TX ready, no RX data
    ria.pushRx(0xAB);
    try std.testing.expectEqual(@as(u8, 0xC0), bus.readByte(0xFFE0, false)); // READY: TX + RX has data
    try std.testing.expectEqual(@as(u8, 0xAB), bus.readByte(0xFFE2, false)); // RX
    try std.testing.expectEqual(@as(u8, 0x80), bus.readByte(0xFFE0, false)); // READY: RX empty again
    bus.writeByte(0xFFE1, 0x58); // TX write (no-op in test, just no crash)

    // $FFE3–$FFFF: still RAM (vectors)
    memory.ram[0xFFFC] = 0x34;
    memory.ram[0xFFFD] = 0x12;
    try std.testing.expectEqual(@as(u8, 0x34), bus.readByte(0xFFFC, false));
    try std.testing.expectEqual(@as(u8, 0x12), bus.readByte(0xFFFD, false));
}

test "RIA UART registers (readByte, pushRx)" {
    // READY ($FFE0): bit 7 = TX ready, bit 6 = RX has data. Empty => 0x80 only.
    try std.testing.expectEqual(@as(u8, 0x80), ria.readByte(ria.ADDR_READY));

    // TX ($FFE1): read is undefined, we return 0
    try std.testing.expectEqual(@as(u8, 0x00), ria.readByte(ria.ADDR_TX));

    // RX ($FFE2): empty => 0
    try std.testing.expectEqual(@as(u8, 0x00), ria.readByte(ria.ADDR_RX));

    // Push a byte; READY gets bit 6 set, RX returns the byte
    ria.pushRx(0xAB);
    try std.testing.expectEqual(@as(u8, 0xC0), ria.readByte(ria.ADDR_READY));
    try std.testing.expectEqual(@as(u8, 0xAB), ria.readByte(ria.ADDR_RX));

    // After read, RX empty again; READY back to 0x80
    try std.testing.expectEqual(@as(u8, 0x80), ria.readByte(ria.ADDR_READY));
    try std.testing.expectEqual(@as(u8, 0x00), ria.readByte(ria.ADDR_RX));

    // writeByte TX: no crash in test (stdout not used when is_test)
    ria.writeByte(ria.ADDR_TX, 0x58);
}
