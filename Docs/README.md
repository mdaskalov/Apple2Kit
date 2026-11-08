# Apple2Kit – notes

A small Apple ][ / ][+ / //e emulator as a Swift package for SwiftUI apps (macOS,
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
| [Emulator.md](Emulator.md) | the code: files, the MOS6502 package, the run loop, sound, inputs, binaries, the headless runner, how to add things (//e, joystick, `.woz`) |
| [../Data/README.md](../Data/README.md) | the scripts: headless runner, disk catalog/extract/list, disassembler, hex dump, hi‑res to PNG, the font |
| [charset.png](charset.png) | the text font (`Charset.swift`) |

## Status (2026‑11‑08)

* **Machines:** Apple ][+ (Applesoft, autostart ROM) and Apple ][ (Integer
  BASIC, original monitor), 48K + 16K language card, NMOS 6502 at
  1.020484 MHz. Apple //e (unenhanced) with 64K: 40 columns, lower case,
  its firmware; no aux memory, so no 80 columns (Hardware.md, *The //e*).
* **Disk II** in slot 6, two drives, nibble level: `.dsk`/`.do`/`.po` (sector
  order detected) and `.nib`. Reading and writing work. Written disks stay in
  memory until saved (`diskFileData(drive:)`). The motor keeps spinning for
  1 s after it is switched off, as on the real card.
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
  mixed mode, pages 1 and 2. Each frame is drawn from memory as it is at
  that moment (no beam racing). `Apple2View` shows it at a scale (1×, 2×…
  of 280 × 192 points) or at any size, at the screen's aspect ratio.
* **Keyboard:** the Mac's (or an iPad's, iPhone's, Apple TV's) keys as the
  ][+'s (capitals, ←/→, Return, Esc, Ctrl), while the view has the focus;
  the on‑screen keyboard on iOS; the Siri Remote on tvOS (../README.md,
  Platforms). `type(_:)` types text. Left/right ⌥
  are push buttons 0/1. The paddles sit in the middle (128).
* **Sound:** the speaker, rendered to the cycle (`SpeakerRenderer`);
  `sound` mutes it. *Fast Disk* (`fastDisk`) doesn't run ahead of the
  clock while the speaker sounds.
* **Not there yet:** joystick, the //e's aux memory and 80 columns, the
  enhanced //e (65C02, MouseText), `.woz`, 13‑sector disks, double hi‑res,
  game controllers. iOS, tvOS, watchOS and visionOS build, but have only
  been tried in an app on the Mac so far.

Tested (headless, `swift test`, and in an app): DOS 3.3 master (boot,
`CATALOG`, `SAVE` then reboot and `LOAD`, also as `.po` and `.nib`),
several boot disks with their own loader; a binary extracted from a disk
(`dsk.py extract` → `load`, on all three). The //e: Applesoft, DOS 3.3
`CATALOG`, a boot disk. Applesoft and the monitor (`F800L`) with no
disk.

On the Apple ][ (not ][+) there is no autostart. RESET goes to the monitor
(`*`). Boot with `C600G` (or `6` Ctrl‑P); Ctrl‑B starts Integer BASIC.
