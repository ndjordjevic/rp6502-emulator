// Standalone test module: CPU + memory integration tests.
// Run with: zig build test

const std = @import("std");
const cpu = @import("cpu.zig");
const memory = @import("memory.zig");

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

    var c = try cpu.Cpu.create(memory.readByte, memory.writeByte);
    defer c.destroy();
    c.reset();

    // Three instructions: LDA, STA, BRK
    _ = c.instCycle();
    _ = c.instCycle();
    _ = c.instCycle();

    try std.testing.expectEqual(@as(u8, 0x42), memory.ram[0]);
    try std.testing.expectEqual(@as(u8, 0x42), c.getA());
}
