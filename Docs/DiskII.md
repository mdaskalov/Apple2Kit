# The Disk II

The controller card with two drives (`Sources/Apple2Kit/Emulator/DiskII.swift`), and
the disks as they are on the surface: tracks of nibbles
(`Sources/Apple2Kit/Emulator/DiskImage.swift`).

## The card's switches

Slot 6: $C0E0‑$C0EF (`$C080 + slot × $10 + n`), boot ROM at $C600. A read or a
write throws the switch.

| n | Switch | Effect |
|---|---|---|
| 0‑7 | phase 0‑3 off/on (n/2 = phase, odd = on) | the head's stepper |
| 8 / 9 | motor off / on | off: after a second (below) |
| A / B | drive 1 / drive 2 | |
| C | Q6L | read mode: the next nibble into the latch, returned. Write mode: the latch onto the disk |
| D | Q6H | load mode (with Q7H, a write puts the value in the latch) |
| E | Q7L | read mode. With Q6H: write‑protect in bit 7 (no disk counts as protected) |
| F | Q7H | write mode |

Reading an even switch returns the latch; odd ones read 0.

**DOS reading:** `LDA $C08C,X / BPL` until bit 7, then compare with
D5 AA 96 and so on.

**DOS writing:** `LDA $C08D,X / LDA $C08E,X / BMI protected`, then
`STA $C08F,X` (latch = $FF, write mode) / `ORA $C08C,X` (shift it out), then
each nibble as `STA $C08D,X` / `ORA $C08C,X`, 32 cycles apart.

## The head

A track is two half tracks. Half track h sits under magnet h mod 4. When a
magnet next to it is on (h + 1 or h − 1 mod 4), the head moves half a track
towards it, once per switch access (`step`). The range is 0‑69 (tracks
0‑34). The boot ROM steps 80 times outwards to find track 0 (the "grinding",
about 1.5 s). Odd half tracks read as the track below; there is no
half‑track data.

When the track changes, the head stays at the same fraction of the way
round, which only matters for `.nib` tracks of different lengths.

## A track of nibbles

A byte on the disk ("nibble", "disk byte") has its high bit set and no two
zero bits in a row. A `.dsk` holds the decoded sectors, so each track is
built (`DiskImage.nibblize`) as DOS 3.3 formats it, 6656 nibbles in all:

```
gap 1: 48 × FF
16 times, physical sector 0‑15:
  address field  D5 AA 96  vol vol  trk trk  sec sec  sum sum  DE AA EB    (4-and-4, volume 254)
  gap 2: 6 × FF
  data field     D5 AA AD  343 nibbles (6-and-2)  DE AA EB
  gap 3: 44 × FF
```

The sync bytes are plain FFs, not the 10‑bit self‑sync of a real disk.

**4‑and‑4:** v as `(v >> 1) | $AA`, `v | $AA`. Decoded:
`((a << 1) | 1) & b`.

**6‑and‑2** (`encode62`/`decode62`, as AppleWin's `Code62`):

1. 86 six‑bit values from the bytes' low two bits, swapped (bit 0 ↔ 1).
   Value i holds those of bytes i, i + 86 and i + 172 (if < 256), in bits
   0‑1, 2‑3 and 4‑5.
2. 256 six‑bit values: each byte's high six bits (`b >> 2`).
3. All 342 values, in this order, each EOR'd with the one before (the first
   with 0), then the last value as the checksum. Each value goes through the
   64‑entry table (`writeTable`, $96 … $FF) as one nibble.

## Sector orders and images

DOS 3.3 and ProDOS put their sectors on the physical sectors in different
orders (interleave), and a 140K image keeps one of the two orders. The
physical sector p of a track holds the image's sector `order.imageSector[p]`:

| Physical | 0 1 2 3 4 5 6 7 8 9 A B C D E F |
|---|---|
| DOS order (`.do`, most `.dsk`) | 0 7 E 6 D 5 C 4 B 3 A 2 9 1 8 F |
| ProDOS order (`.po`) | 0 8 1 9 2 A 3 B 4 C 5 D 6 E 7 F |

The physical sector numbers are in the address fields. That's all that
matters to the code reading them, so a DOS disk works from a `.po` and a
ProDOS disk from a `.do` as long as the image's order is known. ProDOS block
k of a track is ProDOS sectors 2k and 2k+1 (physical
0,2,4,6,8,A,C,E,1,3,5,7,9,B,D,F).

**Detecting a `.dsk`'s order** (`SectorOrder.detect`, also `Data/dsk.py`):

1. A DOS 3.3 VTOC at T17 S0 (file offset $11000 in either order) means DOS
   order. VTOC: catalog track 1‑34, sector < 16, 35 tracks, 16 sectors,
   256 bytes a sector.
2. Else, if block 2 read in ProDOS order is a volume directory (previous
   block 0, storage type $F with a name, entry length $27, $0D entries a
   block) and isn't one in DOS order, it is ProDOS order.
3. Else DOS order. Disks with their own loader (no catalog) are almost
   always DOS‑ordered `.dsk`s.

`.do` is always DOS order, `.po` always ProDOS order.

**Formats** (`DiskImage.init`):

| Image | Size | Taken as |
|---|---|---|
| `.dsk`, `.do`, `.po` | 143360 (35 × 16 × 256) | nibblized as above |
| `.nib` | 232960 (35 × 6656) | the nibbles as they are (copy protection in the nibbles survives) |
| `.woz`, `.d13`, `.2mg`, hard disks | | not yet |

## Timing: how fast the disk turns

A real disk passes one nibble every 32 CPU cycles. A latch read returns
whatever is shifting in at that moment, so a valid byte (bit 7 set) is there
for a while, then partial ones. The emulation is simpler (`readNibble`):

* A read takes the next nibble and returns it with bit 7 set. Read again
  within 32 cycles, the same nibble has bit 7 clear (it is shifting). The
  read after that takes the next nibble.
* If more than 64 cycles passed since the last nibble, the disk has turned
  on by `elapsed / 32` nibbles while the code was away.
* Writes move one nibble per shift.

So code in a tight loop gets every nibble, faster than a real drive and
never missing one. Code that waits sees the disk move on. Both matter:

* **The "is the motor on?" check.** Before each call, DOS's RWTS reads the
  latch twice ~26 cycles apart, eight times. If it never changes, the drive
  is off and RWTS waits about a second for it to spin up. With one nibble
  per read and no "bit 7 clear" state, the head always stopped right
  after a sector, at the start of the 44‑FF gap 3. The check read 16 equal
  FFs and waited every time: a DOS boot took 9 s. With the shifting state,
  two reads never agree on a spinning disk. The boot now takes 3.8 s
  emulated, HELLO included.
* **The motor's run‑on.** $C0E8 doesn't stop the motor at once: the card's
  timer keeps it on for about a second (`spinDownCycles` = 1,000,000), and
  DOS relies on it between calls.

Code that counts cycles between nibbles (some copy protection, nibble
counting, "E7 bitstreams") can fail.
That needs bit‑level timing and `.woz` images.

## Writing

What the controller writes goes into the nibble track (`DiskImage.write`),
and the track is marked dirty. *Save Image As…* (`fileData`) decodes the
dirty tracks: it finds every address field of the right track with a good
checksum and the first data field after it (within 64 nibbles) that
decodes, then stores the sectors back in the image's order. Sectors that
don't decode keep their old data. `.nib` images are saved as the nibbles.

DOS 3.3's `SAVE` checked: boot, save a program, save the image, boot it,
`LOAD` and `RUN`. The VTOC bitmap, catalog, T/S list and data sector were
all written as DOS does it (`dsk.py catalog`/`list` read them back).
`INIT` (format) is untested: it writes whole tracks with timed sync bytes.

The image file is never written. The app reads it once, and you choose
where to save.
