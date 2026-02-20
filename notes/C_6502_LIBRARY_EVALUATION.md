# C 6502 library evaluation

Deep research for **Phase 1.1** of the RP6502 emulator: choosing a C 6502 core to use via Zig C interop. Referenced from [IMPLEMENTATION.md](IMPLEMENTATION.md#11-6502-cpu-core-existing-c-library).

---

**Requirement for RP6502:** The board uses a **W65C02S** (65C02 with WDC extended opcodes: STZ, BRA, PHX/PHY/PLX/PLY, TRB, TSB, WAI, STP, etc.). Any library must support **65C02 / W65C02** and have a **callback-based memory API** for the bus layer. Preference: **reliable, accurate, performant, no known bugs, regularly maintained, permissive license.**

| Library | 65C02 / W65C02 | Callback API | License | Maintained | Tests (Klaus etc.) | Verdict |
|--------|----------------|--------------|---------|------------|--------------------|---------|
| **visrealm/vrEmu6502** | ✅ 6502/6510, 65C02, **WDC65C02**, R65C02 | ✅ `read(addr, isDbg)`, `write(addr, val)` at create | **MIT** | ✅ Commits to Jan 2026, CI (Win/Linux/Pi Pico), multi-contributor | Passes 6502 + decimal + **65C02 decimal** + **65C02 extended** + **W65C02 extended** + R65C02 extended | **Recommended** |
| redcode/6502 | ❌ MOS 6502 only | ✅ `read(context, addr)`, `write(context, addr, val)` | LGPL-3.0 / GPL-3.0 | ✅ Long-lived (1999–2025), used in NEStalin | Accurate, small (~17 KB) | ❌ No 65C02 — unsuitable for RP6502 |
| bzotto/MCS6502 | ❌ NMOS 6502 only (README: "not a 65C02") | ✅ ReadByte/WriteByte + context | (check repo) | Moderate activity | Passes Klaus 6502 functional test | ❌ No 65C02 — unsuitable |
| floooh/chips | ⚠️ Unclear | ⚠️ Pin-mask (uint64_t) tick API, not simple read/write | Zlib | ✅ Active, 1.1k+ stars | chips-test repo; issue #87 re decimal mode | ⚠️ 65C02 opcode set not clearly documented; API heavier to integrate |
| lib6502 (piumarta / larsks) | ⚠️ Typically NMOS | ✅ M6502_setCallback, M6502_Callbacks | MIT | Varies by fork | — | ⚠️ 65C02 support not guaranteed; verify before use |
| rk65c02 (rkujawa) | ✅ WDC 65C02S | — | — | Experimental | BCD, not cycle-exact | ⚠️ Deps (Boehm GC, uthash); experimental |
| lib65ce02 (elmerucr) | 65CE02 (CSG variant) | Musashi-style API | — | Niche | Cycle-exact 65CE02 | Different CPU variant |

## Summary and recommendation

- **vrEmu6502** is the only C library in this set that is **reliable, performant, accurate, and regularly maintained** while offering:
  - **Full W65C02** (including STZ, BRA, PHX/PHY/PLX/PLY, TRB, TSB, WAI, STP, and correct decimal/flag behavior).
  - **Simple callback API:** two function pointers (read, write) passed into `vrEmu6502New(CPU_W65C02, readFn, writeFn)`; optional debug read vs normal read via `isDbg`.
  - **Strong test coverage:** [Klaus2m5/6502_65C02_functional_tests](https://github.com/Klaus2m5/6502_65C02_functional_tests) — 6502 functional, decimal, 65C02 decimal, 65C02 extended, **W65C02 extended**, R65C02 extended; all documented as passing in the repo README.
  - **Maintenance:** Recent fixes (e.g. Windows tests Jan 2026, clang strict prototypes, Pi Pico build, STP behavior, B/U and D/I reset flags, WAI/NMI). CI and multiple contributors.
  - **No external dependencies;** C99; easy to vendor and wire from Zig via `addCSourceFile` and a thin `cpu.zig` wrapper.

**Alternatives if vrEmu6502 is ever unsuitable:** (1) Confirm whether **floooh/chips** `m6502.h` exposes a 65C02/WDC variant and a way to drive it with a single read/write callback; (2) consider **lib6502** only after verifying 65C02 opcode support in the fork you use.
