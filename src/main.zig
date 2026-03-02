// RP6502 emulator — Phase 1: CPU + bus + RIA UART + XRAM portals.
// Run: zig build run          — Hi demo then halt
// Run: zig build run -- echo  — Echo mode (type keys, see them; Ctrl+C to exit)
// Run: zig build run -- xram  — XRAM portal test (writes "OK" to XRAM, reads back, prints)

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

// XRAM test: write "OK" to XRAM at $1000, read back, print, then BRK.
//
//   $0200  A9 00       LDA #$00     ; ADDR0 lo
//   $0202  8D E6 FF    STA $FFE6
//   $0205  A9 10       LDA #$10     ; ADDR0 hi
//   $0207  8D E7 FF    STA $FFE7
//   $020A  A9 01       LDA #$01     ; STEP0 = 1
//   $020C  8D E5 FF    STA $FFE5
//   $020F  A9 4F       LDA #$4F     ; 'O'
//   $0211  8D E4 FF    STA $FFE4    ; write to xram[$1000], ADDR0 += 1
//   $0214  A9 4B       LDA #$4B     ; 'K'
//   $0216  8D E4 FF    STA $FFE4    ; write to xram[$1001], ADDR0 += 1
//   $0219  A9 00       LDA #$00     ; reset ADDR0 lo
//   $021B  8D E6 FF    STA $FFE6
//   $021E  A9 10       LDA #$10     ; reset ADDR0 hi
//   $0220  8D E7 FF    STA $FFE7
//   $0223  AD E4 FF    LDA $FFE4    ; read xram[$1000] = 'O', ADDR0 += 1
//   $0226  8D E1 FF    STA $FFE1    ; print to TX
//   $0229  AD E4 FF    LDA $FFE4    ; read xram[$1001] = 'K', ADDR0 += 1
//   $022C  8D E1 FF    STA $FFE1    ; print to TX
//   $022F  A9 0A       LDA #$0A     ; newline
//   $0231  8D E1 FF    STA $FFE1
//   $0234  00          BRK          ; vector to $0235; main loop exits when PC = XRAM_HALT_ADDR
//
const XRAM_HALT_ADDR: u16 = 0x0235;
fn loadXramTestProgram() void {
    // Reset vector: CPU starts at PROG_START
    memory.ram[RESET_VECTOR_LO] = @truncate(PROG_START);
    memory.ram[RESET_VECTOR_HI] = @intCast(PROG_START >> 8);
    // BRK vector: CPU halts at XRAM_HALT_ADDR
    memory.ram[IRQ_VECTOR_LO] = @truncate(XRAM_HALT_ADDR);
    memory.ram[IRQ_VECTOR_HI] = @intCast(XRAM_HALT_ADDR >> 8);
    memory.ram[XRAM_HALT_ADDR] = 0x00; // BRK (halt trap)
    var p: u16 = PROG_START;

    // ADDR0 lo = $00 (5 bytes)
    memory.ram[p] = 0xA9; // LDA imm
    memory.ram[p + 1] = 0x00;
    p += 2;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE6;
    memory.ram[p + 2] = 0xFF; // $FFE6 = ADDR0 lo
    p += 3;

    // ADDR0 hi = $10 (5 bytes)
    memory.ram[p] = 0xA9; // LDA imm
    memory.ram[p + 1] = 0x10;
    p += 2;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE7;
    memory.ram[p + 2] = 0xFF; // $FFE7 = ADDR0 hi
    p += 3;

    // STEP0 = 1 (5 bytes)
    memory.ram[p] = 0xA9; // LDA imm
    memory.ram[p + 1] = 0x01;
    p += 2;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE5;
    memory.ram[p + 2] = 0xFF; // $FFE5 = STEP0
    p += 3;

    // Write 'O' (0x4F) to xram[ADDR0], ADDR0 += 1 (5 bytes)
    memory.ram[p] = 0xA9; // LDA imm
    memory.ram[p + 1] = 0x4F;
    p += 2;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE4;
    memory.ram[p + 2] = 0xFF; // STA $FFE4 = RW0
    p += 3;

    // Write 'K' (0x4B) to xram[ADDR0], ADDR0 += 1 (5 bytes)
    memory.ram[p] = 0xA9; // LDA imm
    memory.ram[p + 1] = 0x4B;
    p += 2;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE4;
    memory.ram[p + 2] = 0xFF;
    p += 3;

    // Reset ADDR0 = $1000 (10 bytes)
    memory.ram[p] = 0xA9; // LDA imm
    memory.ram[p + 1] = 0x00;
    p += 2;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE6;
    memory.ram[p + 2] = 0xFF;
    p += 3;
    memory.ram[p] = 0xA9; // LDA imm
    memory.ram[p + 1] = 0x10;
    p += 2;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE7;
    memory.ram[p + 2] = 0xFF;
    p += 3;

    // Read xram[ADDR0] into A, ADDR0 += 1; print via STA $FFE1 (TX) (6 bytes)
    memory.ram[p] = 0xAD; // LDA abs
    memory.ram[p + 1] = 0xE4;
    memory.ram[p + 2] = 0xFF;
    p += 3;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE1;
    memory.ram[p + 2] = 0xFF; // STA $FFE1 = TX
    p += 3;

    // Read second byte, print (6 bytes)
    memory.ram[p] = 0xAD; // LDA abs
    memory.ram[p + 1] = 0xE4;
    memory.ram[p + 2] = 0xFF;
    p += 3;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE1;
    memory.ram[p + 2] = 0xFF;
    p += 3;

    // Print newline (0x0A) (5 bytes)
    memory.ram[p] = 0xA9; // LDA imm
    memory.ram[p + 1] = 0x0A;
    p += 2;
    memory.ram[p] = 0x8D; // STA abs
    memory.ram[p + 1] = 0xE1;
    memory.ram[p + 2] = 0xFF;
    p += 3;
    memory.ram[p] = 0x00; // BRK (1 byte) — total 53 bytes → $0235
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
    const xram_mode = args.len > 1 and std.mem.eql(u8, args[1], "xram");

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
    } else if (xram_mode) {
        loadXramTestProgram();
    } else {
        loadDemoProgram();
    }

    var c = try cpu.Cpu.create(bus.readByte, bus.writeByte);
    defer c.destroy();
    c.reset();
    ria.resetXramPortals();

    if (echo_mode) {
        std.debug.print("Echo mode — type keys (Ctrl+C to exit)\n", .{});
        while (!quit_flag.load(.acquire)) {
            ria.pollStdin();
            _ = c.instCycle();
        }
        std.debug.print("\n(6502 stopped)\n", .{});
    } else if (xram_mode) {
        while (c.getPC() != XRAM_HALT_ADDR) {
            ria.pollStdin();
            _ = c.instCycle();
        }
        std.debug.print("(XRAM test done)\n", .{});
    } else {
        while (c.getPC() != HALT_ADDR) {
            ria.pollStdin();
            _ = c.instCycle();
        }
        std.debug.print("\n(6502 halted)\n", .{});
    }
}
