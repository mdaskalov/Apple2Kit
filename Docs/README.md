# Apple2Kit – notes

A small Apple ][ / ][+ / //e / enhanced //e emulator as a Swift package for SwiftUI apps (macOS,
iOS/iPadOS, tvOS, watchOS, visionOS):
boot a disk image, load a binary into memory and run it, or start BASIC from
the ROM, and show it all in a SwiftUI view (`Apple2View`). It runs on the
`MOS6502` package (its own repository, https://github.com/mdaskalov/MOS6502,
Emulator.md). The aim is simple and readable code, not perfect rendering.

| Document | Contents |
|---|---|
| [../README.md](../README.md) | using the package: the model, the view, an example |
| [Hardware.md](Hardware.md) | the machine as emulated: memory map, ROMs, soft switches, language card, keyboard, game I/O, the display's memory and character codes |
| [DiskII.md](DiskII.md) | the Disk II: switches, stepper, the nibble track, 6‑and‑2, sector orders, image formats, the timing model and why, writing |
| [Emulator.md](Emulator.md) | the code: files, the MOS6502 package, the run loop, sound, inputs, binaries, the headless runner, how to add things (bit‑level timing) |
| [Natives.md](Natives.md) | a program's memory by name, for a host that runs Swift in place of some of its 6502 code: symbol maps (one a build of the program), fingerprints of a routine's code, `RAM`, symbol files for the debugger |
| [../Data/README.md](../Data/README.md) | the scripts: headless runner, disk catalog/extract/list, disassembler, hex dump, hi‑res to PNG, the font |
| [charset.png](charset.png) | the text font (`Charset.swift`) |

## Status

* **Machines:** Apple ][+ (Applesoft, autostart ROM) and Apple ][ (Integer
  BASIC, original monitor), 48K + 16K language card, NMOS 6502 at
  1.020484 MHz. Apple //e, unenhanced (6502) and enhanced (65C02), with
  128K (an extended 80‑column card: aux memory, 80 columns), lower case,
  the enhanced //e's MouseText, its firmware (Hardware.md, *The //e*).
* **Disk II** in slot 6, two drives: `.dsk`/`.do`/`.po` (sector order
  detected), `.nib` and `.woz` (WOZ 1 and 2; saved as WOZ2). Reading and
  writing work. Written disks stay in memory until saved
  (`diskFileData(drive:)`). The motor keeps spinning for 1 s after it is
  switched off, as on the real card. The disk turns with
  the CPU's clock; a `.woz` is read bit by bit through the card's
  sequencer, at its bit timing, with bit slips and weak bits (DiskII.md,
  *Timing*).
* **Saved state:** `savedState()` / `restore(_:)`, the whole machine with
  its disks as data, for an app the system may end in the background
  (Emulator.md, *Inputs, disks and binaries*).
* **Binaries:** `load(url/bytes, at:, run:)` puts a file (as `Data/dsk.py
  extract` writes it) into memory and, as `BRUN` does, jumps to it; RTS
  returns to the monitor. The address comes from the call, or from the
  file's name (`NAME#06XXXX.bin`).
* **Without ROMs** (`roms: .none`): for a program that needs none (its own
  code, its own disk routines). The screen starts blank, `print` puts text
  on it (a "Loading..."), `load` runs the program at once.
* **Two types:** `Apple2` (the app's: real time, sound, disks, status;
  `@Observable`) runs an `Apple2Machine` (the hardware alone, also
  headless). Emulator.md, *Apple2 and Apple2Machine*.
* **Display:** 40×24 text in the Apple's font (inverse, flashing; ][+ has no
  lower case), hi‑res in three styles (Color, Color Filled, Mono), lo‑res,
  mixed mode, pages 1 and 2; the //e's 80 columns, double lo‑res and
  double hi‑res (140 × 192 in the 16 colours, 560 dots in Mono). Each frame is drawn from memory as it is at
  that moment (no beam racing). `Apple2View` shows it at a scale (1×, 2×…
  of 280 × 192 points) or at any size, at the screen's aspect ratio.
* **Keyboard:** the Mac's (or an iPad's, iPhone's, Apple TV's) keys as the
  ][+'s (capitals, ←/→, Return, Esc, Ctrl), while the view has the focus;
  the on‑screen keyboard on iOS; the Siri Remote on tvOS (../README.md,
  Platforms). `type(_:)` types text. Left/right ⌥
  are push buttons 0/1. The paddles sit in the middle (128).
* **Sound:** the speaker, rendered to the cycle (`SpeakerRenderer`);
  `sound` mutes it, `volume` (0–1, default 0.5) sets its loudness.
  *Fast Disk* (`fastDisk`) doesn't run ahead of the clock while the
  speaker sounds.
* **Symbols** (Natives.md): a program's variables, tables and
  routines by name in a `SymbolMap`, the CPU's memory by those names for
  Swift that stands in for 6502 code (`RAM`), a routine's code checked by
  its fingerprint, and the names as a symbol file for AppleWin's and
  Mariani's debugger. Hooks: Swift where the CPU reaches an address,
  switched on and off by name, the trap bits theirs.
* **Not there yet:** joystick, 13‑sector disks, game controllers. iOS,
  tvOS, watchOS and visionOS build, but have only been tried in an app on
  the Mac so far.

Tested (headless, `swift test`, and in an app): DOS 3.3 master (boot,
`CATALOG`, `SAVE` then reboot and `LOAD`, also as `.po`, `.nib` and `.woz`),
copy‑protected `.woz` originals (custom loaders, 18‑sector tracks), the
WOZ reference test images (applesaucefdc.com; two need a //e),
several boot disks with their own loader; a binary extracted from a disk
(`dsk.py extract` → `load`, on all of them). The //e: Applesoft, DOS 3.3
`CATALOG`, a boot disk; both //e's: `PR#3` (80 columns), a 128K double
hi‑res game (RAMRD, RAMWRT, ALTZP, page flipping). The 65C02 against
AppleWin's (the MOS6502 package's `cpu_check`). Applesoft and the monitor (`F800L`) with no
disk.

On the Apple ][ (not ][+) there is no autostart. RESET goes to the monitor
(`*`). Boot with `C600G` (or `6` Ctrl‑P); Ctrl‑B starts Integer BASIC.
