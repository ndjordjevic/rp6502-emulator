# UART: Concepts, RP Pico, RP6502 RIA, and the Emulator

Quick reference for continuing work on the RP6502 emulator (`ria.zig`) and understanding how UART works across all layers.

**Sources:** Picocomputer [RIA docs](https://picocomputer.github.io/ria.html), [notes/ria/UART.md](UART.md), RP2040/RP2350 datasheets, Pico C SDK, rp6502 firmware (`com.h`, `com.c`, `ria.c`).

---

## 1. UART in General (What You Need to Know)

### Core idea
- **UART** = Universal **Asynchronous** Receiver/Transmitter. No shared clock; both sides agree on **baud rate** (bits per second). Data is framed with start/stop bits so the receiver can sync.
- **Wiring:** TX on A → RX on B, RX on A → TX on B (plus GND).
- **Frame:** Idle HIGH; then Start (LOW) + 5–8 data bits (LSB first) + optional parity + 1–2 stop bits (HIGH). Common: **8N1** = 8 data, no parity, 1 stop.
- **Baud rate:** Must match on both sides (e.g. 115200). One “symbol” per bit in UART, so often used interchangeably with “bits per second”.

### For the emulator
- You don’t emulate the wire (start/stop bits, baud). You only emulate the **software view**: status flags + TX byte + RX byte (and buffers behind them).
- READY bits = “can I send?” and “is there data to read?” — same idea as any UART status register.

---

## 2. How RP Pico Implements UART (RP2040 / RP2350)

### Hardware
- **Two UARTs:** `uart0`, `uart1`. ARM PL011-style: UARTDR (data), UARTFR (flags), UARTIBRD/UARTFBRD (baud divisor), UARTLCR_H (format), UARTCR (enable).
- **FIFOs:** 32 bytes TX, 32 bytes RX. Flags: TXFF (TX FIFO full), RXFE (RX FIFO empty), TXFE (TX FIFO empty), RXFF (RX FIFO full), BUSY.
- **Baud:** Fractional divider (16-bit integer + 6-bit frac) from `clk_peri`; produces internal clock at 16× baud for sampling.

### Pico C SDK usage (what RIA firmware uses)
- `uart_init(uart, baud)` — enable UART, set baud, 8N1, FIFOs.
- `gpio_set_function(pin, GPIO_FUNC_UART)` — assign TX/RX pins.
- `uart_putc_raw(uart, c)` / read from `uart_get_hw(uart)->dr` for data.
- Poll flags: `uart_get_hw(uart)->fr & UART_UARTFR_TXFF_BITS` (full?), `uart_is_readable(uart)` (data?).

### Default Pico (board) UART0
- GPIO 0 = TX, GPIO 1 = RX, 115200 8N1. RIA uses **UART1** on GPIO 4 (TX) and 5 (RX) at 115200.

### For the emulator
- You are **not** emulating the Pico’s UART hardware or SDK. You are emulating the **RIA register API** ($FFE0–$FFE2) that the 6502 sees. That API is a minimal “status + TX byte + RX byte” view; the real firmware translates it to/from Pico UART and circular buffers.

---

## 3. How RP6502 / Picocomputer Implements UART (RIA $FFE0–$FFE2)

### Register map (official: picocomputer.github.io/ria.html)

| Address | Name   | Access  | Meaning |
|---------|--------|---------|--------|
| $FFE0   | READY  | Read    | Bit 7 = TX ready (buffer has space). Bit 6 = RX has data. |
| $FFE1   | TX     | Write   | Write byte to send. |
| $FFE2   | RX     | Read    | Read received byte. |

115200 8N1. READY is intended for use with 6502 **BIT** (e.g. BIT $FFE0 → N flag = bit 7, V flag = bit 6).

### Data path in firmware

- **`com.h` / `com.c`**
  - **UART:** `uart1`, 115200, TX=GPIO 4, RX=GPIO 5.
  - **TX:** 32-byte circular buffer `com_tx_buf[]`; `com_tx_writable()` = “space for one more byte”; `com_tx_write(ch)` enqueues; `com_tx_task()` drains buffer into Pico UART.
  - **RX:** 32-byte circular buffer + single-byte `com_rx_char` (-1 = empty) for the RIA action loop. `com_rx_task()` fills from UART (and keyboard); action loop moves one byte from buffer into `com_rx_char` when 6502 hasn’t consumed it yet.

- **`ria.c`** (action loop when 6502 accesses RIA)
  - **CASE_READ(0xFFE0):** Sync READY from com state: bit 7 = `com_tx_writable()`, bit 6 = (com_rx_char >= 0). If RX data available and not yet in REGS(0xFFE2), copy com_rx_char → REGS(0xFFE2), set bit 6, clear com_rx_char.
  - **CASE_WRITE(0xFFE1):** If `com_tx_writable()`, `com_tx_write(data)`. Then set/clear READY bit 7 from current `com_tx_writable()`.
  - **CASE_READ(0xFFE2):** Return REGS(0xFFE2) (already filled by READ of $FFE0 or previous logic); optionally sync com_rx_char into REGS(0xFFE2)/REGS(0xFFE0) and mark consumed.

So on real hardware: 6502 reads $FFE0 to get/update READY and to “latch” RX into $FFE2; writes $FFE1 to send; reads $FFE2 to get the latched RX byte.

### For the emulator
- Emulate the **same register semantics**: READY (bit 7 = can send, bit 6 = RX has data), TX write = send one byte, RX read = consume one byte. You can use a single RX buffer and “latch” one byte for $FFE2 if you want to mirror hardware; your current design (READY from buffer state, RX read = pop from buffer) is equivalent for 6502 code that polls READY then reads RX.

---

## 4. How Your Emulator (`ria.zig`) Implements It

### Registers (matches RIA spec)
- **$FFE0 READY (read):** Bit 7 = TX ready (you currently always set it; no FIFO backpressure). Bit 6 = RX has data (rx_read != rx_write).
- **$FFE1 TX (write):** Byte → stdout (or no-op in tests).
- **$FFE2 RX (read):** One byte from RX circular buffer; consumed on read. If buffer empty, return 0 (and READY bit 6 should be 0).

### State
- **TX:** No buffer; write goes straight to stdout. So “TX ready” is always true (hence READY bit 7 always set).
- **RX:** Circular buffer `rx_buf[256]`, indices `rx_read` / `rx_write`. `pushRx()` for tests or stdin; `pollStdin()` in main loop to fill from stdin (non-blocking; Windows TBD).

### Callbacks
- **readByte(addr):** $FFE0 → READY; $FFE1 → 0 (TX write-only); $FFE2 → consume and return next RX byte (or 0 if empty).
- **writeByte(addr, val):** $FFE0 no-op; $FFE1 → write val to stdout; $FFE2 no-op.

### What you need to keep in mind
1. **READY bit 7:** Real hardware can clear it when TX buffer is full (32 bytes). Your “always ready” is a valid simplification for terminal-style use; if you ever add a TX buffer, you’d clear bit 7 when full.
2. **READY bit 6:** Must be 1 only when there is at least one byte to read from $FFE2. Your `rx_read != rx_write` is correct.
3. **RX read when empty:** Returning 0 and READY bit 6 = 0 is correct. 6502 code should check BIT $FFE0 (V flag = bit 6) before reading $FFE2.
4. **pollStdin():** Must be called from the main emulator loop so that keypresses end up in the RX buffer and READY bit 6 becomes set.

---

## 5. Minimal “Need to Know” Checklist for the Emulator

- **UART concept:** Async serial; baud + frame (8N1); status “can send?” / “data ready?” + TX/RX data. You only emulate that register view.
- **RP Pico:** Two UARTs, FIFOs, SDK `uart_init`/`uart_putc_raw`/flags. Relevant only to understand where RIA’s bytes go; you don’t emulate Pico.
- **RIA:** $FFE0 = READY (7=TX, 6=RX), $FFE1 = TX write, $FFE2 = RX read; 115200 8N1. Firmware uses com_* buffers + Pico UART; you substitute host stdin/stdout + a single RX buffer.
- **ria.zig:** READY reflects TX “always ready” and RX buffer non-empty; TX write → stdout; RX read → pop from buffer; pollStdin() fills buffer. Same semantics as RIA for 6502 code that uses BIT $FFE0 and then read/write TX/RX.

---

## 6. Where to Read More (from your resources)

| Topic | Where |
|-------|--------|
| UART concepts, framing, baud | rp6502-learning [notes/ria/UART.md](../rp6502-learning/notes/ria/UART.md) §§1–3; “Knowing the RP2040”; “Programming the Pico/W” |
| RP2040/RP2350 UART registers | RP2040/RP2350 datasheet (UART chapter); rp6502-learning notes/ria/UART.md §4 |
| Pico SDK UART API | RP-009085 (Pico C SDK); rp6502-learning notes/ria/UART.md §6 |
| RIA register spec | https://picocomputer.github.io/ria.html |
| RIA firmware (com + ria) | rp6502 `src/ria/sys/com.h`, `com.c`, `ria.c` (CASE_READ/CASE_WRITE 0xFFE0–0xFFE2) |

This file and rp6502-learning [notes/ria/UART.md](../rp6502-learning/notes/ria/UART.md) together give you everything needed to work on the emulator and understand `ria.zig` in the context of UART, Pico, and RP6502 RIA.
