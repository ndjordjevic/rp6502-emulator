// Raw terminal mode and restore on exit (Unix/macOS).
// Only used when stdin is a TTY; no-op when piped or in tests.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Enter raw mode: no echo, no line buffering. Returns saved termios for restore.
/// Returns null when not a TTY (piped) or on Windows. Call restore() on exit.
pub fn enterRawMode() !?posix.termios {
    if (builtin.os.tag == .windows) return null;
    const fd = posix.STDIN_FILENO;
    const saved = posix.tcgetattr(fd) catch return null;
    var raw = saved;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    try posix.tcsetattr(fd, .NOW, raw);
    return saved;
}

/// Restore terminal to saved termios. Call on exit (e.g. defer).
pub fn restore(saved: ?posix.termios) void {
    const s = saved orelse return;
    if (builtin.os.tag == .windows) return;
    posix.tcsetattr(posix.STDIN_FILENO, .NOW, s) catch {};
}
