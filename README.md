# Apple2Kit

An Apple ][ / ][+ / //e (64K) emulator as a Swift package, for SwiftUI apps on
macOS 14, iOS/iPadOS 17, tvOS 17, watchOS 10 and visionOS 1 or later:
48K + language card, Disk II (`.dsk`, `.do`, `.po`, `.nib`, read and write),
text, lo‑res and hi‑res, the speaker, the keyboard. The CPU is the
`MOS6502` package ([github.com/mdaskalov/MOS6502](https://github.com/mdaskalov/MOS6502),
version 1.0.0).

## Use

Add the package to the app (*File ▸ Add Package Dependencies… ▸ Add Local…*
→ this folder), then:

```swift
import Apple2Kit
import SwiftUI

struct ContentView: View {
    @State private var apple = Apple2(model: .apple2Plus)  // ][+, Applesoft

    var body: some View {
        Apple2View(apple, style: .color, scale: 2)         // scale nil: any size, 280:192
            .background(.black)
            .task {
                apple.insert(diskURL, boot: true)            // boot a disk
                // or: apple.load(binaryURL, at: 0x4000)      // a binary, BRUN
                // or: apple.startBASIC()                     // whatever is in the ROM
            }
    }
}
```

A game that needs no ROM (its own code, its own disk routines) runs
without them, on a blank screen:

```swift
@State private var apple = Apple2(model: .apple2Plus, roms: .none)
…
Apple2View(apple).task {
    apple.print("Loading...")                    // centred on the text screen
    apple.insert(diskURL)                        // drive 1, not booted
    apple.load(binaryURL, at: 0x0DFB)
}
```

Without ROMs nothing runs before `load`, so text `print`ed first stays on
the screen until the program switches to graphics. (With ROMs, `load` on a
fresh machine first runs the ROM's start‑up, which clears the screen: print
after it.)

Or the view holds a machine of its own, set up once when it first appears
(for an app that doesn't touch the machine again):

```swift
Apple2View(.apple2, roms: .none) { apple in
    apple.load(binaryURL, at: 0x1100)
}
```

Two types: `Apple2` is what an app holds – the machine run in real time,
with sound, disks, binaries and a status for a UI (`@Observable`).
`Apple2Machine` (`apple.machine`) is the hardware alone – CPU, memory,
switches, drives, cards – with no clock, sound or UI, also used headless.

* `Apple2(model: .apple2Plus / .apple2 / .apple2e, roms: .bundle / .directory(url) / .none)`:
  the machine as the app runs it. `restart()`
  (power cycle: boots drive 1), `startBASIC()`, `reset()` (Ctrl‑RESET),
  `togglePause()`, `step()`; `insert` / `eject` / `diskFileData` for disks;
  `load(url or bytes, at:, run:)` for binaries; `print(_:atX:y:uppercased:cls:)`
  (row 0‑23, centred without `atX`, cut off at the row's ends; capitals on
  the ][ and ][+) and `cls()` on text page 1; `type(_:)`, `screenText`,
  `memoryDump`; `sound`, `fastDisk`, `model`; status for a UI: `drives`,
  `registers`, `videoMode`, `speed`, `paused`, `message`; `machine` (the
  hardware, an `Apple2Machine`) for the rest.
* `Apple2View(apple, style:, scale:)`: shows and runs it (a display link),
  takes the keys while focused (Platforms, below). `style`: `.color`, `.filled`, `.monochrome`.
  `scale`: points per Apple dot (1, 2, 3…), or nil for any size at the
  screen's aspect ratio. `Apple2View(model, roms:, style:, scale:) { setup }`:
  with a machine of its own, made and set up once.
* Without the UI, for a host that runs its own loop (the emulator core,
  `Sources/Apple2Kit/Emulator`): `Apple2Machine` (from
  `ROMs.machine(model, roms:)`; `run(cycles:)`, `print`/`cls`, `clicks` /
  `takeClicks()` for the speaker, `hiresScreen()`), `HiresScreen` (a page's
  8K as lines, `dots(of:into:)`), `Screen.image` / `Screen.thumbnail` (a
  `HiresScreen` in a `Screen.Style`; the colours as `Screen.RGB`),
  `SpeakerRenderer` / `SpeakerStream` (clicks → samples) and `SoundPlayer`
  (streamed clicks, or a whole sound's samples).
* A host's machine: `Apple2Machine(model:, rom: nil, diskROM: nil)` (or
  `roms: .none`) has no ROMs (the language card's RAM always read and
  written, $C080‑$C08F pick the bank; the text page starts blank); `load(memory:languageCard:)` fills it; `insert(_:slot:)` puts an
  `Apple2Card` (its ROM page, its switches) in a slot; `ioHook` takes
  soft switches of $C000‑$C0FF over; `copy()` makes an independent machine.
  The language card's RAM, while read and written, lies in `cpu.mem` at
  $D000‑$FFFF (`languageCardRAM` has all 16K, `languageCardBank` the bank).
* A binary is the file's bytes alone, as `Data/dsk.py extract` writes it;
  `load` jumps to it as `BRUN` does (RTS: the monitor's `*`).
  Without an address, `load` takes it from the name (`NAME#06XXXX.bin`, which
  `dsk.py extract` writes), else $0800.

### Examples

```swift
// where the ROMs come from
let apple = Apple2(model: .apple2e)                              // the app's bundle
let apple = Apple2(model: .apple2e, roms: .directory(romsURL))   // a folder
let apple = Apple2(model: .apple2Plus, roms: .none)              // none: a blank screen

// text on the screen (text page 1, 40 × 24)
apple.print("Loading...")                            // centred on row 12, the screen cleared first
apple.print("PRESS ANY KEY", y: 23, cls: false)      // the bottom row, the rest kept
apple.print("SCORE 0", atX: 0, y: 0, cls: false)     // top left
apple.print("Hello", uppercased: false)              // as given: the //e shows lower case
apple.cls()                                          // all blank

// disks and binaries
apple.insert(diskURL)                                // drive 1, not booted
apple.insert(diskURL, drive: 1)                      // drive 2
apple.insert(diskURL, boot: true)                    // drive 1, power cycle and boot it
apple.load(binaryURL)                                // at the name's address (GAME#064000.bin), else $0800
apple.load(bytes, at: 0x0300, run: false)            // into memory only, nothing started

// the keyboard
apple.type("CATALOG\n")                              // key by key, as fast as the program takes them
apple.press(0x1B)                                    // one key: Esc

// the hardware underneath
apple.machine.paddles[0] = 255                       // paddle 0 all the way
apple.machine.ioHook = { address, write, value in    // your own soft switches
    address == 0xC0F0 && !write ? 0x42 : nil         // nil: the Apple's own
}
```

A view with a machine of its own, a game started on a blank screen:

```swift
struct ContentView: View {
    var body: some View {
        Apple2View(.apple2Plus, roms: .none) { apple in
            apple.print("Loading...")
            apple.insert(Bundle.main.url(forResource: "GAME", withExtension: "dsk")!)
            apple.load(Bundle.main.url(forResource: "GAME", withExtension: "bin")!, at: 0x0DFB)
        }
    }
}
```

`swift test` runs the tests (Applesoft, a binary loaded and run, the
language card, a machine without ROMs, cards and the I/O hook, `print`;
the ones that need ROMs are skipped without them, below).

* [Docs](Docs/README.md): the machine, the Disk II, the code, status, next steps.
* [Data](Data/README.md): a headless runner (~100× real time), disk
  catalog/extract/BASIC listing, disassembler, hex dump, hi‑res to PNG.

## Platforms

The emulator (`Sources/Apple2Kit/Emulator`) is Foundation and CoreGraphics
only. `Apple2View` and its keys differ:

| Platform | View | Keys |
|---|---|---|
| macOS | `NSView`, display link | the keyboard (a click gives the view the focus); left/right ⌥ the push buttons |
| iOS, iPadOS, visionOS | `UIView`, `CADisplayLink` | a hardware keyboard as on the Mac (the view takes it at once); else a tap shows the on‑screen keyboard with a bar for esc, ctrl and the arrows, a tap again hides it |
| tvOS | `UIView`, `CADisplayLink` | a hardware keyboard; the Siri Remote: arrows, select (RETURN), play/pause (space) |
| watchOS | SwiftUI `TimelineView` | none: give the app buttons that call `press(_:)` or `type(_:)` |

Sound plays on all of them (`AVAudioEngine`; on iOS, tvOS, watchOS and
visionOS the audio session is set to `.ambient`: it mixes with other sound
and the silent switch mutes it).

## ROMs

The package emulates the hardware only: it has no ROMs. The app provides
them, as files named after the model, with the Disk II's boot ROM:

| File | Size | Contents |
|---|---|---|
| `apple2.rom` | 12K (12288) | Apple ][: $D000‑$FFFF (Integer BASIC, the original monitor) |
| `apple2plus.rom` | 12K (12288) | Apple ][+: $D000‑$FFFF (Applesoft, the autostart monitor) |
| `apple2e.rom` | 16K (16384) | Apple //e (unenhanced): $C000‑$FFFF |
| `disk2.rom` | 256 | the Disk II boot ROM (P5, 16 sectors) |

Only the model's ROM and `disk2.rom` are needed. By default they are
looked up in the app's bundle: put them in the app project's
`Resources/roms` (or anywhere in its resources), Xcode copies them into
the bundle. Elsewhere:

```swift
Apple2(model: .apple2e, roms: .directory(URL(fileURLWithPath: "/path/to/roms")))
let machine = try ROMs.machine(.apple2e, roms: .directory(romsURL))   // the hardware, without the UI
```

A ROM missing or of the wrong size is a programming error in
`Apple2` (`fatalError` with the file's name); `ROMs.machine` throws
`ROMs.ROMError`. For `swift test` and `Data/headless.sh`, put the ROMs in
`roms/` in this folder (git‑ignored) or set `APPLE2_ROMS` to their
directory; the tests that need them are skipped without them.
