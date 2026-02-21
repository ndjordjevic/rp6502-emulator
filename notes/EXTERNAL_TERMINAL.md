# Connecting an External Terminal to the Emulator

Ways to use an **external terminal** (e.g. Terminal.app) as the "serial console" for the emulator, like connecting to a real RP6502. The emulator keeps using stdin/stdout; no code changes required for options 1–3.

---

## 1. Named pipes (FIFOs) — no code change

Create two FIFOs and redirect the emulator's stdin/stdout to them. The external terminal reads from one and writes to the other.

**Setup once:**
```bash
mkfifo /tmp/rp6502_uart_in /tmp/rp6502_uart_out
```

**Terminal A (runs the emulator; can be IDE or background):**
```bash
cd ~/CProjects/rp6502-emulator
zig build run < /tmp/rp6502_uart_in > /tmp/rp6502_uart_out
```

**Terminal B (external, e.g. Terminal.app):**
- To see output: `cat /tmp/rp6502_uart_out`
- To send input: `cat > /tmp/rp6502_uart_in` (type then Ctrl+D, or keep it open)

You can use two tabs in the external terminal (one for `cat` out, one for `cat >` in), or combine with a small script. The emulator sees whatever is written to `uart_in` as keyboard input and sends its UART TX output to `uart_out`.

---

## 2. tmux / screen — no code change

Run the emulator inside a tmux (or screen) session; "connect" by attaching from the external terminal.

**From IDE or any terminal:**
```bash
cd ~/CProjects/rp6502-emulator
tmux new -s rp6502 'zig build run'
```

**From external Terminal.app:**
```bash
tmux attach -t rp6502
```

You then see and interact with the emulator in the external terminal. Same process, different window — not a separate "serial" link, but no setup beyond tmux.

---

## 3. socat virtual serial pair — no code change

Use `socat` to create two linked PTYs (like a virtual serial cable). Emulator uses one end; the other end is opened by a terminal program (e.g. `screen`, `minicom`).

**Terminal A:** Create the pair and run the emulator on one end. (One common approach: run `socat` so one PTY is for the emulator; in another step run the emulator with stdio redirected to that PTY. Alternatively run the emulator in the background with its stdio tied to one PTY.)

Example pattern (adjust to your setup):
```bash
# Create linked PTYs
socat PTY,link=/tmp/rp6502_emu,raw,echo=0 PTY,link=/tmp/rp6502_term,raw,echo=0
```
Then run the emulator with stdin/stdout connected to one of the PTYs (e.g. `zig build run </tmp/rp6502_emu >/tmp/rp6502_emu` in another terminal, or via a small wrapper).

**Terminal B (external):**
```bash
screen /tmp/rp6502_term
# or: minicom -D /tmp/rp6502_term
```

This mimics "real serial": two ends of a virtual cable; the external terminal attaches to one end.

---

## 4. TCP/socket (future — requires code change)

If the emulator gains a "serial over TCP" mode (e.g. listen on port 6502; one client connection becomes the UART stream), then from the external terminal:

```bash
nc localhost 6502
# or: telnet localhost 6502
```

That would feel like connecting to a device on a network/serial port but requires implementing a socket server in the emulator.

---

## Summary

| Method        | Code change? | Feel                         | Complexity   |
|---------------|--------------|------------------------------|--------------|
| FIFOs         | No           | Two "ends" to attach         | Low          |
| tmux/screen   | No           | Same session, different window | Very low  |
| socat PTY pair| No           | Like virtual serial          | Medium       |
| TCP (nc)      | Yes          | Like real serial over network| Medium (later) |

For "connect from an external terminal like in real life" **without changing code**, the practical options are **FIFOs** (external terminal uses `cat` to/from the pipes) or **socat + screen** (virtual serial pair; attach to one end). **tmux** is the simplest way to just use the external terminal for the same run.
