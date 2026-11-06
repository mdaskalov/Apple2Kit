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
    @State private var emulator = EmulatorModel()          // ][+, Applesoft

    var body: some View {
        Apple2View(emulator, style: .color, scale: 2)     // scale nil: any size, 280:192
            .background(.black)
            .onAppear {
                emulator.insert(diskURL, drive: 0, boot: true)       // boot a disk
                // or: emulator.load(binaryURL, at: 0x4000, run: true)  // a binary, BRUN
                // or: emulator.startBASIC()                           // whatever is in the ROM
            }
    }
}
```

* `EmulatorModel(model: .apple2Plus / .apple2 / .apple2e)`: the machine. `restart()`
  (power cycle: boots drive 1), `startBASIC()`, `reset()` (Ctrl‑RESET),
  `togglePause()`, `step()`; `insert` / `eject` / `diskFileData` for disks;
  `load(url or bytes, at:, run:)` for binaries; `type(_:)`, `screenText`,
  `memoryDump`; `sound`, `fastDisk`, `model`; status for a UI: `drives`,
  `registers`, `videoMode`, `speed`, `paused`, `message`; `machine` for the
  rest.
* `Apple2View(emulator, style:, scale:)`: shows and runs it (a display link),
  takes the keys while focused (Platforms, below). `style`: `.color`, `.filled`, `.monochrome`.
  `scale`: points per Apple dot (1, 2, 3…), or nil for any size at the
  screen's aspect ratio.
* A binary is the file's bytes alone, as `Data/dsk.py extract` writes it;
  `load` jumps to it as `BRUN` does (RTS: the monitor's `*`).
  Without an address, `load` takes it from the name (`NAME#06XXXX.bin`, which
  `dsk.py extract` writes), else $0800.

`swift test` runs the tests (Applesoft, a binary loaded and run; ROMs below).

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
EmulatorModel(model: .apple2e, romDirectory: URL(fileURLWithPath: "/path/to/roms"))
let machine = try ROMs.machine(.apple2e, from: romsURL)   // an Apple2 without the UI
```

A ROM missing or of the wrong size is a programming error in
`EmulatorModel` (`fatalError` with the file's name); `ROMs.machine` throws
`ROMs.ROMError`. For `swift test` and `Data/headless.sh`, put the ROMs in
`roms/` in this folder (git‑ignored) or set `APPLE2_ROMS` to their
directory; the tests that need them are skipped without them.
