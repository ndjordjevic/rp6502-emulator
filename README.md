# RP6502 Emulator

Cross-platform emulator for the [Picocomputer RP6502](https://picocomputer.github.io/), written in [Zig](https://ziglang.org/).

## Goals

- **Phase 1:** Emulate the RIA (Interface Adapter) only — 6502 CPU, RAM, XRAM, RIA registers, OS API, monitor. Use host terminal (stdin/stdout) as console; no VGA. Matches real hardware used without VGA Pico (serial console).
- **Phase 2 (later):** Emulate VGA Pico and draw the screen.

## Platform

- **Language:** Zig
- **Targets:** Linux, macOS, Windows (cross-platform via Zig’s build system)

## Build

Requires [Zig](https://ziglang.org/download/) (0.13+ recommended).

```bash
cd rp6502-emulator
zig build
zig build run
```

## Project layout

```
rp6502-emulator/
├── build.zig        # Build script
├── build.zig.zon    # Package manifest
├── README.md
└── src/
    └── main.zig     # Entry point (placeholder)
```

## References

- [Picocomputer documentation](https://picocomputer.github.io/)
- [RP6502-RIA](https://picocomputer.github.io/ria.html) — register map, UART, XRAM, OS calls
- [RP6502-OS](https://picocomputer.github.io/os.html) — ABI, syscalls
- [RP6502 firmware (C)](https://github.com/picocomputer/rp6502) — reference implementation
