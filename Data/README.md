# Data – tools

Run them from this folder. Python 3 with no dependencies; Swift via `swiftc`
(Xcode). The MOS6502 sources are cloned from GitHub (tag `$MOS6502_REF`,
default `1.0.0`; `main` works too), or taken from `$MOS6502_PACKAGE` (a local
working copy) if set. The ROMs: `--roms DIR`, `$APPLE2_ROMS`, else
`../roms` (README.md).

| Script | Purpose |
|---|---|
| `headless.sh`, `headless.swift` | the emulator core (`Sources/Apple2Kit/Emulator`) without an app, about 100× real time, driven by a script of actions (below) |
| `mos6502.sh` | sourced by `headless.sh`: compiles the MOS6502 package into a module and sets `$MOS6502` (swiftc flags) |
| `dsk.py` | inside a 140K image: `info` (order, DOS 3.3/ProDOS), `catalog`, `extract` a file (a binary named `NAME#06XXXX.bin` for *Load Binary*), `list` an Applesoft program, hex dump a `sector`/`block`, `convert` between DOS and ProDOS order |
| `dis6502.py` | 6502 disassembler: `dis6502.py FILE START END [BASE]` |
| `hexdump.py` | hex dump with the Apple text column: `hexdump.py FILE START END [BASE]` |
| `hires.py` | hi‑res page → PNG: `hires.py MEM.bin OUT.png [2000\|4000]`; also `row_addr`, `write_png` |

## headless.sh

```
./headless.sh [--roms DIR] [--model plus|ii|e] ACTION...
  --disk PATH / --disk2 PATH   insert a disk image in drive 1 / 2
  --eject / --eject2           take it out
  --power                      power cycle (the ][+ boots drive 1)
  --basic                      power cycle into BASIC, disks or not
  --reset                      the RESET key
  --run SECONDS                run the CPU that long (emulated time)
  --until TEXT [SECONDS]       run until TEXT is on the text screen (at most 30 s)
  --type TEXT                  type TEXT (\n: RETURN) and run until it is taken
  --screen                     print the text screen
  --status                     print CPU, switches, drives
  --style color|filled|mono    how --png colours the screen (default color)
  --png PATH                   write the display as a PNG (560 x 384)
  --wav PATH                   write the speaker since the start (or the last --wav) as a WAV
  --dump PATH                  write the 64K memory (and PATH.lc: the language card's 16K)
  --save-disk PATH             write drive 1's image with what was written to it
  --nib PATH                   write drive 1's nibble tracks as a .nib
```

The machine powers on before the first action. The text screen and the
speed are printed at the end. Examples:

```sh
./headless.sh --run 1 --type 'PRINT 2+2\n'                       # Applesoft, no disk
./headless.sh --model ii --run 1 --type 'F800L\n'                # the old monitor
./headless.sh --disk dos33_master.dsk --power --until 'GLAD TO MEET' 10 \
    --type 'CATALOG\n' --run 1                                  # DOS 3.3
./headless.sh --disk game.dsk --power --run 12 --status --png /tmp/game.png \
    --style filled --png /tmp/game_filled.png --style mono --png /tmp/game_mono.png
./headless.sh --run 1 --wav /tmp/beep.wav --type 'PRINT CHR$(7)\n' --wav /tmp/bell.wav   # the speaker
./headless.sh --disk game.dsk --power --run 20 --dump /tmp/mem.bin && \
    python3 dis6502.py /tmp/mem.bin 0800 0900                    # look at its code
# writing: save a program, keep the image, check it
./headless.sh --disk copy.dsk --power --run 5 --type 'NEW\n10 PRINT "HI"\nSAVE T\n' \
    --run 3 --save-disk /tmp/saved.dsk && python3 dsk.py list /tmp/saved.dsk T
```

`--until` looks at the whole text screen: `]` matches "APPLE ][", so wait
for something the program prints instead.

## dsk.py

```sh
python3 dsk.py info disks/*.dsk                 # which are DOS 3.3, ProDOS, own loader
python3 dsk.py catalog disk.dsk
python3 dsk.py extract disk.dsk MYPROG          # B files: MYPROG#06XXXX.bin, XXXX the load address
python3 dsk.py list disk.dsk HELLO              # Applesoft listing
python3 dsk.py sector disk.dsk 17 0             # the VTOC
python3 dsk.py convert disk.dsk disk.po         # same disk, ProDOS order
```

Disks with their own loader (most games) have no catalog: use
`sector`/`block`, or boot them with `headless.sh --dump` and disassemble.
