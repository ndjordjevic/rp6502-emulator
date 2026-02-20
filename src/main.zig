const std = @import("std");

pub fn main() !void {
    std.debug.print("RP6502 Emulator — Phase 1 (RIA + terminal)\n", .{});
    std.debug.print("Cross-platform: Linux, macOS, Windows\n", .{});
    std.debug.print("Zig {s}\n", .{@import("builtin").zig_version_string});
    std.debug.print("(Placeholder — 6502 core and RIA emulation to be added)\n", .{});
}
