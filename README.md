# SHC Cheats for PS3 — Super Heroine Chronicle (BLJS10244)

**v0.9 (beta)** — released 2026-10-17. See [Version and changelog](#version-and-changelog).

Working cheats for **Super Heroine Chronicle** on a **real PS3**. No Artemis, no emulator, no debug unit.

| Cheat | Type | Verified on hardware |
|---|---|---|
| Infinite SP | EBOOT code patch | ✅ ON → OFF → ON cycled in battle |
| Unlimited Turns | EBOOT code patch | ✅ ON → OFF → ON cycled in battle |
| God mode (HP lock) | Live RAM lock | ✅ HP showed 9999 on the TV (see [status](#god-mode-status)) |

Everything runs from a PC on the same LAN, talking to **webMAN MOD's PS3MAPI** HTTP endpoints.

---

## Why not Artemis

Artemis crashes this console every time. So none of this uses it.

The tools talk straight to webMAN MOD's built-in memory engine over plain HTTP. Same result, nothing extra to install, nothing that can crash the console:

```
GET http://<PS3IP>/getmem.ps3mapi?proc=<pid>&addr=0x924C0&len=4
GET http://<PS3IP>/setmem.ps3mapi?proc=<pid>&addr=924C0&oper=0&val=48000008
```

`oper` accepts `0`=Set, `38`=And, `124`=Or, `94`=Xor, `43`=Add, `45`=Sub.

A browser is enough. The `.ps1` scripts just wrap these calls.

---

## Quick start

**One-time setup** — the scripts need your PS3's IP address. Each `.ps1` ships with the placeholder `$IP = "PS3_IP_HERE"` and **refuses to run until you change it**; open the script in a text editor and set `$IP` near the top (see [Changing the IP](#changing-the-ip)).

1. Turn on the PS3 and **start the game** (title screen or a battle).
2. On the PC, double-click:
   - `Cheats-ON.bat` — Infinite SP + Unlimited Turns
   - `HP-GodMode.bat` — god mode (leave the window open). **God mode needs a live battle** — run it once you are in one, not at the title screen.
3. Go back to the game. Cheats are active immediately.

Stop god mode with `HP-GodMode-OFF.bat`, or close its window / press Ctrl+C.

---

## Files

| File | What it does |
|---|---|
| `Cheats-ON.bat` / `Cheats-OFF.bat` / `Cheats-STATUS.bat` | apply / revert / check Infinite SP + Unlimited Turns |
| `shc_cheats.ps1` | the tool behind those three `.bat` files |
| `HP-GodMode.bat` | find the live HP field and lock it |
| `HP-FIND.bat` | locate the HP field, read-only, writes nothing |
| `HP-GodMode-OFF.bat` | restore natural HP and clear the lock state |
| `shc_godmode.ps1` | the god-mode tool itself |
| `SHC_cheats.ncl` | the codes in Artemis format — **reference only**, Artemis crashes |
| `shc_hp_lock.ps1` | **legacy**, superseded by `shc_godmode.ps1` (see below) |

---

## The codes

Verified byte-for-byte against a running BLJS10244 ver 01.00 EBOOT:

| Cheat | Offset | Original | Patched |
|---|---|---|---|
| Infinite SP | `0x0924C0` | `40800008` (beq) | `48000008` (b — always taken) |
| Unlimited Turns | `0x1AC22C` | `80840000` (lwz) | `38800001` (li r4, 1) |

These are 32-bit PowerPC instructions patched live in the game's RAM.

---

## God mode

### How it was found

God mode needed a different approach, because the HP value is data, not code.

1. **Dump the heap** over PS3MAPI — a 76 MB region at `0x30000000`.
2. **Diff two snapshots** taken before and after the character took one hit. The exact HP was known both times (`1920` → `557`), so the search was for the single 32-bit word that made that transition.
3. That isolated **exactly one address in 76 MB** — `0x32B91C24` — and the surrounding struct confirmed it:

   | Offset | Before | After | Meaning |
   |---|---|---|---|
   | `+0x00` | 1920 | 557 | HP |
   | `+0x04` | 159 | 159 | stable stat word |
   | `+0x08` | 211 | 106 | SP — matched the on-screen SP exactly |
   | `+0x0C` | 1270 | 768 | |
   | `+0x10` | 1272 | 1210 | |
   | `+0x14` | 1170 | 1170 | stable stat word |

4. **Write and verify**: `setmem` `0000270F` → read back `9999`, HP bar on the TV showed **9999**.

### How the shipped tool re-finds it

The address moves every battle and every launch, so nothing is hardcoded.

The game keeps a **static "base" copy** of a character's stat block, sitting exactly `0x374` (884) bytes **before** the live copy battle actually uses. Its first two words are `[full HP, 159]` — big-endian, so `1920, 159` is the byte string `000007800000009F`.

So the tool:

1. Sweeps the heap in 8 MB windows for that 8-byte signature.
2. Adds `0x374` to get the live HP field.
3. **Validates** the live struct (`live+0x04` equals the `$Sig2` signature word, default `159`, and HP is plausible) before writing anything.
4. Locks HP with a ~300 ms `setmem` loop, since the game recomputes HP during battle.
5. **Re-scans automatically** if the value stops sticking (i.e. the battle object moved).

If validation fails it refuses and writes nothing. Her natural HP is saved to `hp_lock_state.txt` so `HP-GodMode-OFF.bat` can restore it.

### God mode status

The finder **was verified once**: it located the field, wrote `9999`, and the HP bar showed `9999` on real hardware.

What is **not yet re-verified** is the auto re-acquire path — the battle ended before a second fresh battle could be run end-to-end. `HP-FIND.bat` is read-only, so it's safe to test the finder without touching anything.

### If it says "no match"

The search signature starts with the character's **full (undamaged) HP**, which changes with level and equipment. If she's not level 35, read her max HP off the bar and pass it:

```
powershell -ExecutionPolicy Bypass -File shc_godmode.ps1 -MaxHP 1428
```

Other useful parameters: `-Value 5000` (lock value), `-IntervalMs 500` (slower, less network traffic), `-Mode status` (re-find the field and report HP/SP without writing).

---

## Legacy: `shc_hp_lock.ps1`

An earlier "classic trainer narrowing" tool: `find` → take a hit → `narrow` → `lock`. It works, but it needs you to manually read HP off screen and re-narrow each time.

**Superseded by `shc_godmode.ps1`**, which auto-locates the field from the stat-block signature. Kept for reference.

---

## Discovered facts and gotchas

These cost the most time. Written down so nobody repeats them.

### The console

- **The PS3 is big-endian** (PowerPC). `557` is the bytes `00 00 02 2D`, `9999` is `0000270F`. The first three diff passes decoded little-endian and found *nothing at all*. **If a search comes up empty, check endianness first.**
- Live process map for BLJS10244 01.00: `0x10000000` (~4 MB), `0x20000000` (~4 MB), `0x30000000`→`0x34C00000` (**76 MB heap**), `0x40000000` (~4 MB). Everything else unmapped.
- The process id shows up as `pid=` on `http://<PS3IP>/cpursx.ps3`. It changes every launch, so the scripts scrape it instead of hardcoding it.
- **`$PID` is a reserved variable in PowerShell** — use `$proc` instead, and run scripts with `-NoProfile -ExecutionPolicy Bypass -File`.

### The PS3MAPI API

- `dump=` is **parsed as hex** and rounded up to a 64 KB boundary. Passing a decimal size silently gives a different size than requested.
- `len=` per read is capped at **256 bytes**.
- `find` returns the **start address as its "not-found" sentinel**, and only reaches **~16 MB forward** per call. Iterate strictly forward and sweep in windows.
- `setmem` `addr=` takes **no `0x` prefix**; `getmem` `addr=` **does**.
- Errors surface as `Error: <signed int>`.
- The PS3MAPI server is **single-threaded** — parallel requests drop connections mid-run. Read sequentially, or retry.

### Searching memory

- **Single-value searches are unusable.** A region around `0x30CFE000` holds large ascending/descending integer tables, so *every* small integer appears there hundreds of times — `1920` alone had **184 aligned hits**. Only diff-based search isolates the real field.
- **The heap churns hard.** Between snapshots, regions get unmapped mid-read and values turn into `3F800000` (float `1.0`) or `5555`/`AAAA` fill as objects are freed. Take the two dumps as close together as possible and only diff the common length.
- After a battle ends, the stat block is freed — the old address reads back as float fill. **God mode must be run during a battle.**

---

## Safety

- **RAM only.** Nothing on the PS3's hard drive or flash is modified. Reboot and the game is 100% stock. There is nothing to uninstall.
- **Re-apply each launch.** Memory is wiped when the game closes.
- **CFW agnostic.** Anything running webMAN MOD with its web server on port 80 — any CFW, DEX or CEX. Only the game's EBOOT version matters (01.00), not the firmware.
- **Never writes blind.** Both tools check the expected current value first and skip anything unexpected.

---

## Changing the IP

Each `.ps1` has `[string] $IP = "PS3_IP_HERE"` at the top. Replace that placeholder with your console's address, or pass it per-run (which also satisfies the guard):

```
powershell -NoProfile -ExecutionPolicy Bypass -File shc_cheats.ps1 -IP <your-ps3-ip>
```

Find it on the console itself: XMB → Settings → Network Settings → Connection Status → IP Address, or check what `webMAN` reports on `http://<your-ps3-ip>/cpursx.ps3`.

---

## Version and changelog

**Current: v0.9 (beta)** — 2026-10-17.

This is the first tagged release. It is a **beta** on one specific point: Infinite SP,
Unlimited Turns and the god-mode *finder* are hardware-verified, but god mode's
**auto re-acquire path** is not yet re-verified (see [God mode status](#god-mode-status)).
Everything else is stable.

### Compatibility

| | |
|---|---|
| Game | Super Heroine Chronicle, title id **BLJS10244** |
| EBOOT version | **01.00** (the only version tested; other versions have different offsets) |
| Console | any PS3 running **webMAN MOD** with its web server on port 80 — any CFW, DEX or CEX |
| Not required | Artemis (it crashes), a debug unit, an emulator |
| Host | Windows PC on the same LAN — the `.ps1` scripts use PowerShell |

### What is verified on hardware

| Feature | Status |
|---|---|
| Infinite SP | ✅ verified — ON → OFF → ON cycled in battle |
| Unlimited Turns | ✅ verified — ON → OFF → ON cycled in battle |
| God mode — finder | ✅ verified once — located the field, HP bar showed 9999 on the TV |
| God mode — auto re-acquire | ⚠️ **not yet re-verified** — the battle ended before a second battle could be run end-to-end |

### Changelog

- **v0.9** (2026-10-17) — first tagged release.
  - Infinite SP and Unlimited Turns, patched live via PS3MAPI.
  - `shc_godmode.ps1`: auto-locates the HP field from a stat-block signature and locks it.
  - `HP-FIND.bat`: read-only finder, safe to run.
  - `shc_hp_lock.ps1`: kept as a legacy alternative (manual narrowing).
  - README: documented the discovered PS3MAPI and memory-search gotchas.

### Older tags

The `release` tag is an earlier snapshot from the same day and is **superseded by v0.9**.
It ships a README that lists a `README.txt` file which was never uploaded. Use v0.9 or later.

---

## Credits

English patch: [deucebucket/sabers-shc-english-patch](https://github.com/deucebucket/sabers-shc-english-patch).

Findings also posted to [issue #11](https://github.com/deucebucket/sabers-shc-english-patch/issues/11#issuecomment-6240717246).
