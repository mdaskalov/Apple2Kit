# The machine as emulated

An Apple ][ or ][+ with 48K of RAM, a 16K language card in slot 0 and a
Disk II controller in slot 6. Code: `Sources/Apple2Kit/Emulator/Apple2.swift`.

## Memory map

| Range | What | In the code |
|---|---|---|
| $0000‑$BFFF | RAM | `cpu.mem`, read and written by the CPU directly |
| $0400‑$07FF / $0800‑$0BFF | text and lo‑res page 1 / 2 | (RAM) |
| $2000‑$3FFF / $4000‑$5FFF | hi‑res page 1 / 2 | (RAM) |
| $C000‑$C0FF | soft switches, slot I/O | `io` |
| $C100‑$C7FF | slot ROMs: $C600 (Disk II boot ROM) and the cards' (`insert`, their page in `cpu.mem`), the rest reads 0 | `read` |
| $C800‑$CFFF | slots' shared ROM: none, reads 0 | `read` |
| $D000‑$FFFF | ROM (12K), or the language card's RAM | `read`/`write`, `LanguageCard`; RAM read and written: `cpu.mem` |

The `MOS6502` CPU has a flat 64K `mem`. Every page from $C0 up is one of its
*I/O pages* (`cpu.ioPages`): reads and writes there go through
`Apple2.read`/`write`, which picks the switch, the ROM or the language card's
RAM – but while the language card's RAM is read and written, it lies in
`mem` itself (the selected $D000 bank and $E000‑$FFFF, `mapLanguageCard`;
a bank switch swaps $D000‑$DFFF) and $D0‑$FF are no I/O pages: code in the
card's RAM runs as fast as below $C000, and a host reads it in place.
Without ROMs (`Apple2(model:, rom: nil, diskROM: nil)`, a host's machine)
it always is.  A host's own switches go first (`ioHook`). Below $C000 nothing is in the way: the hot path (zero page, stack,
program code in RAM) is a plain array access. Code running in ROM (BASIC,
the monitor) goes through a closure on every fetch. That is fast enough
(about 100× real time in a release build).

The stack (`push`/`pull` in the CPU) and the display read `cpu.mem` directly.
That is right for a ][+, and for the 64K //e here, which has no auxiliary
memory. A 128K //e would need more (Emulator.md).

## ROMs

Not part of the package: the app provides them (`ROMs`, README.md).

| File | Size | Contents |
|---|---|---|
| `apple2plus.rom` | 12K | $D000‑$FFFF of the ][+: Applesoft + autostart monitor; RESET $FA62 |
| `apple2.rom` | 12K | $D000‑$FFFF of the ][: (Programmer's Aid at $D000), Integer BASIC at $E000, original monitor; RESET $FF59 |
| `disk2.rom` | 256 | the Disk II boot ROM (P5, 16 sectors) at $C600 |
| `apple2e.rom` | 16K | $C000‑$FFFF of the unenhanced //e: its firmware at $C100‑$CFFF (80 columns at $C300/$C800), Applesoft and the monitor at $D000 |

The enhanced //e's ROM isn't used (it needs a 65C02).

**Booting:** at power‑on the ][+'s autostart ROM scans the slots from 7
down for a disk controller ($Cn01 = $20, $Cn03 = $00, $Cn05 = $03) and jumps
to the first. If there is none, it starts Applesoft. To get BASIC with no
disk, the Disk II's ROM is visible only while a drive has a disk.
*Start BASIC* hides it until the code first reads the keyboard with no key
waiting. By then the slot scan is over and BASIC waits at `]`, and `PR#6`
works again.

Power‑on clears RAM to 0. Applesoft then sees $03F4 ≠ $03F3 EOR $A5 and does
a cold start. On the ][, whose monitor doesn't clear the screen, 0 shows as
a screen of inverse `@`.

## Soft switches ($C000‑$C0FF)

A read or a write of the address throws the switch (`io`). Reads return 0
where nothing drives the bus. There is no floating‑bus emulation.

| Address | Read/write | Effect |
|---|---|---|
| $C000‑$C00F | R | keyboard: last key, bit 7 set while new |
| $C010‑$C01F | R/W | clear the keyboard strobe (bit 7) |
| $C020 | | cassette out (ignored) |
| $C030‑$C03F | R/W | speaker click: its cycle into `clicks` (the app's sound, below) |
| $C040 | | utility strobe (ignored) |
| $C050 / $C051 | R/W | graphics / text |
| $C052 / $C053 | R/W | full screen / mixed (graphics + 4 text lines) |
| $C054 / $C055 | R/W | page 1 / page 2 |
| $C056 / $C057 | R/W | lo‑res / hi‑res |
| $C058‑$C05F | | annunciators (ignored) |
| $C060 | R | cassette in (0) |
| $C061‑$C063 | R | push buttons 0‑2, bit 7 (⌥ left/right = 0/1) |
| $C064‑$C067 | R | paddle timers 0‑3, bit 7 set for 11 × value cycles after $C070 |
| $C070 | R/W | start the paddle timers |
| $C080‑$C08F | R/W | language card (below) |
| $C090‑$C0FF | | slot n I/O at $C080 + n × $10; slot 6 = $C0E0‑$C0EF: the Disk II (DiskII.md) |

## Language card ($C080‑$C08F)

16K of RAM for $D000‑$FFFF: $E000‑$FFFF once, $D000‑$DFFF twice (bank 1 and
bank 2). Address bits of $C080 + n:

| n | Read | Write |
|---|---|---|
| 0 / 8 | RAM | protected |
| 1 / 9 | ROM | RAM, after two reads in a row |
| 2 / A | ROM | protected |
| 3 / B | RAM | RAM, after two reads in a row |

Bit 3 picks the bank: 0‑3 are bank 2, 8‑B bank 1. Write‑enable ("pre‑write")
needs two *reads* of an odd switch in a row. A write to an odd switch
doesn't count and clears pre‑write. Any access to an even switch protects
the RAM. This follows AppleWin and *Understanding the Apple II* 5‑23. RESET
and power‑on: read ROM, write RAM, bank 2.

## Keyboard

`Apple2.press(ascii)` puts the key in the latch with bit 7 set; reading
$C010 clears it. `KeyMap` maps the Mac's keys (and a hardware keyboard's on
iOS, tvOS, visionOS: the same) to ASCII:

| Mac | Apple | Code |
|---|---|---|
| letters | capitals (the ][+ has no lower case) | $41‑$5A |
| Return, Enter | RETURN | $0D |
| ←, delete | ← (backspace) | $08 |
| → | → (retype) | $15 |
| ↑ / ↓ | Ctrl‑K / Ctrl‑J (as the //e's arrows) | $0B / $0A |
| esc | ESC | $1B |
| Ctrl + letter or @ [ \ ] ^ _ | control code | $00‑$1F |

Characters come from the Mac's layout (`event.characters`), so `[ ] @ \ |`
typed with ⌥ (German layout) arrive as themselves. ⌘ keys go to the menus.

`Apple2.type(text)` (*Paste as Keys*) queues keys. Each one goes in when the
latch is clear and 2000 cycles have passed since the code cleared it.

## The display

`Screen.render` draws the screen from memory once per frame, in the mode the
switches are in at that moment. It draws the video's dots: 560 × 192, two
dots a pixel, shown twice as high (560:384). Text and lo‑res use two dots a
pixel. Hi‑res needs the dots, because a byte with the palette bit set is
shown half a pixel to the right. Three styles (`Screen.Style`, `Apple2View`'s `style`):

| Style | Hi‑res | Text, lo‑res |
|---|---|---|
| Color | colours with dark gaps, the half‑pixel shift | white text, 16 colours |
| Color Filled | colours filled in, no shift | white text, 16 colours |
| Mono | green dots, the half‑pixel shift | green |

**Text rows** are interleaved: row r starts at
`page + (r mod 8) × $80 + (r div 8) × $28`. Bytes $x78‑$x7F of each $80 are
the "screen holes" (used by the firmware and the slots).

**Character codes** (][ and ][+):

| Code | Shows |
|---|---|
| $00‑$1F | inverse @ A‑Z [ \ ] ^ _ |
| $20‑$3F | inverse space ! " … 0‑9 … ? |
| $40‑$7F | the same, flashing (inverse about 2 times a second) |
| $80‑$BF | normal @…_ then space…? |
| $C0‑$FF | normal, as $80‑$BF (no lower case: $E0‑$FF show as $A0‑$BF) |

The font is `Charset.glyphs`: 96 glyphs (ASCII $20‑$7F, 8 rows × 7 dots,
bit 0 leftmost), made by `Data/charset.py` from a bitmap
font file. The //e shows the lower case at $E0‑$FF; with
ALTCHARSET ($C00F) $40‑$7F are inverse instead of flashing, $60‑$7F lower
case (MouseText, the enhanced //e's, isn't there).

## The //e

`Apple2.Model.apple2e`, the unenhanced //e with 64K (no aux memory, no
80‑column card):

* **ROM:** 16K from $C000. $D000‑$FFFF as on the ][+. $C100‑$CFFF is
  its own firmware when INTCXROM ($C007) is on; $C300 is (unless
  SLOTC3ROM, $C00B), and reading it brings in $C800‑$CFFF until $CFFF is
  touched. Otherwise the slots' ROMs (the Disk II's at $C600).
* **Switches** ($C000‑$C00F written): 80STORE, RAMRD, RAMWRT, INTCXROM,
  ALTZP, SLOTC3ROM, 80COL, ALTCHARSET, off/on. Read at $C011‑$C01F, bit 7,
  with BSRBANK2, BSRREADRAM, VBL ($C019: 1 outside the vertical blank,
  from the cycle count) and the video switches; only $C010 clears the
  keyboard strobe.
* **No aux memory:** with RAMRD/RAMWRT on, pages $02‑$BF go through
  `read`/`write`: reads give 0, writes go nowhere. ALTZP and 80STORE change
  nothing (80STORE keeps PAGE2 from switching the page shown). So `PR#3`
  (80 columns) doesn't work: half its characters go to aux memory.
* **Keyboard:** lower case from the Mac's keys and in `type`. The
  unenhanced //e's Applesoft takes commands in capitals only (caps lock).

**Lo‑res:** each text byte is two blocks, low nibble on top. 16 colours
(`Screen.loresColours`).

**Hi‑res lines:** line y starts at
`page + (y mod 8) × $400 + ((y div 8) mod 8) × $80 + (y div 64) × $28`.
Each byte holds 7 pixels (bit 0 leftmost) plus a palette bit (bit 7).
Colours (`Screen.HiresLine`: `draw`, `filledColour`):

* a lit pixel next to another lit one: white;
* a lit pixel alone: violet/green (palette bit clear) or blue/orange (set),
  by even/odd column;
* an unlit pixel between two lit ones (a gap in a colour): their colour,
  at 40 % brightness in *Color* (`gapShade`), full in *Color Filled*.

The pixels are then placed on the dots (`hiresDots`). A byte's 7 pixels
take the 14 dots from column × 14. With the palette bit set, the byte is one
dot later: the dot it skips repeats the dot before it, and its last half
pixel takes the next byte's first dot when that byte isn't shifted.
*Color Filled* doesn't shift: each pixel is two dots where its column is.
There are no NTSC artefacts beyond that.

**Mixed:** graphics for rows 0‑19 (lines 0‑159), text rows 20‑23.

## The speaker

Each access to $C030 flips the speaker's cone. The machine records the
CPU cycle of each click (`Apple2.clicks`, when not nil). `EmulatorModel` takes
them each frame (`takeClicks`) and renders them to the cycle
(`Emulator/Speaker.swift`, `SpeakerRenderer`):

* the sound is a square wave with an edge at every click;
* each 44.1 kHz sample (23.14 cycles) is the average of the wave over it;
* a high pass at about 35 Hz takes out the DC, as the speaker's coupling
  does, so the cone settles after the last click.

`SpeakerStream` keeps the cone and the filter from frame to frame. A
stretch of sound goes on through silences of up to ¼ s, then rests. A new
stretch starts with 1/25 s of silence ahead, so a late frame doesn't break
it up. `UI/SoundPlayer.swift` queues the samples on an `AVAudioPlayerNode`;
a new stretch first drops what is still queued, so it plays at once.

The ][+ beeps at power‑on: the monitor's BELL, 192 clicks in about 0.1 s,
about 940 Hz (`Data/headless.sh --run 1 --wav beep.wav`).
