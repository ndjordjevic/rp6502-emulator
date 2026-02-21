// RP6502 emulator — Phase 1: CPU + bus + RIA UART (terminal I/O).
// Run: zig build run          — Hi demo then halt
// Run: zig build run -- echo  — Echo mode (type keys, see them; Ctrl+C to exit)

const std = @import("std");
const builtin = @import("builtin");
const cpu = @import("cpu.zig");
const memory = @import("memory.zig");
const bus = @import("bus.zig");
const ria = @import("ria.zig");
const terminal = @import("terminal.zig");

const RESET_VECTOR_LO: u16 = 0xFFFC;
const RESET_VECTOR_HI: u16 = 0xFFFD;
const IRQ_VECTOR_LO: u16 = 0xFFFE;
const IRQ_VECTOR_HI: u16 = 0xFFFF;

// Program: print "Hi\n" via RIA TX ($FFE1) then BRK. Halt when PC = $0210.
const PROG_START: u16 = 0x0200;
const HALT_ADDR: u16 = 0x0210;

// Echo mode: SIGINT sets this; main loop exits and defer restores terminal.
var quit_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Demo program: print "Hi\n" then BRK; reset/BRK vectors point so emulator halts at $0210.
//
//   $0200  A9 48       LDA #$48     ; 'H'
//   $0202  8D E1 FF    STA $FFE1    ; send to RIA TX
//   $0205  A9 69       LDA #$69     ; 'i'
//   $0207  8D E1 FF    STA $FFE1
//   $020A  A9 0A       LDA #$0A     ; newline
//   $020C  8D E1 FF    STA $FFE1
//   $020F  00          BRK          ; vector to $0210; main loop exits when PC = HALT_ADDR
//
fn loadDemoProgram() void {
    memory.ram[RESET_VECTOR_LO] = @truncate(PROG_START);
    memory.ram[RESET_VECTOR_HI] = @intCast(PROG_START >> 8);
    memory.ram[IRQ_VECTOR_LO] = @truncate(HALT_ADDR);
    memory.ram[IRQ_VECTOR_HI] = @intCast(HALT_ADDR >> 8);
    // At $0210: BRK (halt)
    memory.ram[HALT_ADDR] = 0x00; // BRK
    // At $0200: LDA #'H', STA $FFE1, LDA #'i', STA $FFE1, LDA #'\n', STA $FFE1, BRK
    var p: u16 = PROG_START;
    memory.ram[p] = 0xA9;
    memory.ram[p + 1] = 0x48; // 'H'
    p += 2;
    memory.ram[p] = 0x8D;
    memory.ram[p + 1] = 0xE1;
    memory.ram[p + 2] = 0xFF; // STA $FFE1
    p += 3;
    memory.ram[p] = 0xA9;
    memory.ram[p + 1] = 0x69; // 'i'
    p += 2;
    memory.ram[p] = 0x8D;
    memory.ram[p + 1] = 0xE1;
    memory.ram[p + 2] = 0xFF;
    p += 3;
    memory.ram[p] = 0xA9;
    memory.ram[p + 1] = 0x0A; // newline
    p += 2;
    memory.ram[p] = 0x8D;
    memory.ram[p + 1] = 0xE1;
    memory.ram[p + 2] = 0xFF;
    p += 3;
    memory.ram[p] = 0x00; // BRK
}

// Echo program: read from RIA RX, write to RIA TX, loop forever.
//
//   $0200  2C E0 FF   BIT $FFE0     ; N=TX ready, V=RX has data
//   $0203  50 FB      BVC $0200     ; wait for RX: loop while V clear
//   $0205  AD E2 FF   LDA $FFE2     ; A = received byte
//   $0208  2C E0 FF   BIT $FFE0     ; re-read READY (TX ready?)
//   $020B  10 FB      BPL $0208     ; wait for TX: loop while N clear
//   $020D  8D E1 FF   STA $FFE1     ; send byte to TX
//   $0210  4C 00 02   JMP $0200     ; repeat
//
fn loadEchoProgram() void {
    memory.ram[RESET_VECTOR_LO] = @truncate(PROG_START);
    memory.ram[RESET_VECTOR_HI] = @intCast(PROG_START >> 8);
    var p: u16 = PROG_START;
    memory.ram[p] = 0x2C;
    memory.ram[p + 1] = 0xE0;
    memory.ram[p + 2] = 0xFF; // BIT $FFE0
    p += 3;
    memory.ram[p] = 0x50;
    memory.ram[p + 1] = 0xFB; // BVC -5 (loop)
    p += 2;
    memory.ram[p] = 0xAD;
    memory.ram[p + 1] = 0xE2;
    memory.ram[p + 2] = 0xFF; // LDA $FFE2
    p += 3;
    memory.ram[p] = 0x2C;
    memory.ram[p + 1] = 0xE0;
    memory.ram[p + 2] = 0xFF; // BIT $FFE0 (TX ready)
    p += 3;
    memory.ram[p] = 0x10;
    memory.ram[p + 1] = 0xFB; // BPL -5 (wait_tx)
    p += 2;
    memory.ram[p] = 0x8D;
    memory.ram[p + 1] = 0xE1;
    memory.ram[p + 2] = 0xFF; // STA $FFE1
    p += 3;
    memory.ram[p] = 0x4C;
    memory.ram[p + 1] = 0x00;
    memory.ram[p + 2] = 0x02; // JMP $0200
}

fn sigintHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    quit_flag.store(true, .release);
}

pub fn main() !void {
    const saved_termios = try terminal.enterRawMode();
    defer terminal.restore(saved_termios);

    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    const echo_mode = args.len > 1 and std.mem.eql(u8, args[1], "echo");

    if (echo_mode) {
        quit_flag.store(false, .release);
        if (builtin.os.tag != .windows) {
            const posix = std.posix;
            var sigact = posix.Sigaction{
                .handler = .{ .handler = sigintHandler },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.INT, &sigact, null);
        }
        loadEchoProgram();
    } else {
        loadDemoProgram();
    }

    var c = try cpu.Cpu.create(bus.readByte, bus.writeByte);
    defer c.destroy();
    c.reset();

    if (echo_mode) {
        std.debug.print("Echo mode — type keys (Ctrl+C to exit)\n", .{});
        while (!quit_flag.load(.acquire)) {
            ria.pollStdin();
            _ = c.instCycle();
        }
        std.debug.print("\n(6502 stopped)\n", .{});
    } else {
        while (c.getPC() != HALT_ADDR) {
            ria.pollStdin();
            _ = c.instCycle();
        }
        std.debug.print("\n(6502 halted)\n", .{});
    }
}
