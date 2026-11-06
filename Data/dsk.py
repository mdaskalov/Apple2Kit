#!/usr/bin/env python3
"""Look inside 140K Apple II disk images (.dsk/.do/.po): DOS 3.3 and ProDOS.

Usage:
  dsk.py info IMAGE...            sector order, operating system, volume
  dsk.py catalog IMAGE            the files (ProDOS: every directory)
  dsk.py extract IMAGE NAME [OUT] a file's contents (DOS: without the length/address
                                  header; ProDOS: the data fork; PATH/NAME in folders);
                                  default OUT: NAME.bin, a binary NAME#06XXXX.bin (its
                                  load address, which the emulator's Load Binary takes)
  dsk.py list IMAGE NAME          an Applesoft program as text
  dsk.py sector IMAGE T S         hex dump of track T, sector S (DOS logical numbering)
  dsk.py block IMAGE N            hex dump of ProDOS block N
  dsk.py convert IMAGE OUT        the same disk in the other sector order (.po <-> .dsk/.do)

The order of a .dsk is detected as the emulator does (`SectorOrder.detect`,
Docs/DiskII.md): a DOS 3.3 VTOC at T17 S0 means DOS order, else a ProDOS
volume directory at block 2 in ProDOS (and not DOS) order means ProDOS order.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hexdump import dump  # noqa: E402

SIZE = 35 * 16 * 256
# physical sector -> sector in the file, for each order
DOS_ORDER = [0x0, 0x7, 0xE, 0x6, 0xD, 0x5, 0xC, 0x4, 0xB, 0x3, 0xA, 0x2, 0x9, 0x1, 0x8, 0xF]
PRODOS_ORDER = [0x0, 0x8, 0x1, 0x9, 0x2, 0xA, 0x3, 0xB, 0x4, 0xC, 0x5, 0xD, 0x6, 0xE, 0x7, 0xF]
PRODOS_TO_PHYSICAL = [0x0, 0x2, 0x4, 0x6, 0x8, 0xA, 0xC, 0xE, 0x1, 0x3, 0x5, 0x7, 0x9, 0xB, 0xD, 0xF]
DOS_TO_PHYSICAL = [DOS_ORDER.index(s) for s in range(16)]

DOS_TYPES = {0x00: "T", 0x01: "I", 0x02: "A", 0x04: "B", 0x08: "S", 0x10: "R", 0x20: "a", 0x40: "b"}
PRODOS_TYPES = {0x00: "UNK", 0x04: "TXT", 0x06: "BIN", 0x0F: "DIR", 0x19: "ADB", 0x1A: "AWP", 0x1B: "ASP",
                0xB3: "S16", 0xEF: "PAS", 0xF0: "CMD", 0xFA: "INT", 0xFB: "IVR", 0xFC: "BAS", 0xFD: "VAR",
                0xFE: "REL", 0xFF: "SYS"}

TOKENS = ("END FOR NEXT DATA INPUT DEL DIM READ GR TEXT PR# IN# CALL PLOT HLIN VLIN HGR2 HGR HCOLOR= HPLOT "
          "DRAW XDRAW HTAB HOME ROT= SCALE= SHLOAD TRACE NOTRACE NORMAL INVERSE FLASH COLOR= POP VTAB HIMEM: "
          "LOMEM: ONERR RESUME RECALL STORE SPEED= LET GOTO RUN IF RESTORE & GOSUB RETURN REM STOP ON WAIT "
          "LOAD SAVE DEF POKE PRINT CONT LIST CLEAR GET NEW TAB( TO FN SPC( THEN AT NOT STEP + - * / ^ AND "
          "OR > = < SGN INT ABS USR FRE SCRN( PDL POS SQR RND LOG EXP COS SIN TAN ATN PEEK LEN STR$ VAL ASC "
          "CHR$ LEFT$ RIGHT$ MID$").split()
assert len(TOKENS) == 0xEB - 0x80


def apple(b):
    """Text in Apple's high-bit ASCII as a string."""
    return "".join(chr(c & 0x7F) if 0x20 <= c & 0x7F < 0x7F else "." for c in b)


class Image:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        if len(self.data) != SIZE:
            sys.exit(f"{path}: {len(self.data)} bytes, not a 140K image")
        ext = self.path.suffix.lower()
        if ext == ".po":
            self.order = "prodos"
        elif ext == ".do" or self.has_vtoc():
            self.order = "dos"
        elif self.is_volume_dir(PRODOS_ORDER) and not self.is_volume_dir(DOS_ORDER):
            self.order = "prodos"
        else:
            self.order = "dos"

    # sectors and blocks

    def physical(self, track, p, order=None):
        order = order or (DOS_ORDER if self.order == "dos" else PRODOS_ORDER)
        o = track * 4096 + order[p] * 256
        return self.data[o:o + 256]

    def sector(self, track, s):
        """DOS 3.3 logical sector s of track."""
        return self.physical(track, DOS_TO_PHYSICAL[s])

    def block(self, n, order=None):
        t, k = divmod(n, 8)
        return b"".join(self.physical(t, PRODOS_TO_PHYSICAL[s], order) for s in (2 * k, 2 * k + 1))

    def has_vtoc(self):
        v = self.data[17 * 4096:17 * 4096 + 256]   # T17 S0 is file sector 0 in either order
        return 1 <= v[1] <= 34 and v[2] < 16 and v[0x34] == 35 and v[0x35] == 16 and v[0x36] == 0 and v[0x37] == 1

    def is_volume_dir(self, order):
        b = self.block(2, order)
        return b[0] == 0 and b[1] == 0 and b[4] >> 4 == 0xF and b[4] & 0xF and b[0x23] == 0x27 and b[0x24] == 0x0D

    def system(self):
        if self.has_vtoc():
            return "DOS 3.3"
        if self.is_volume_dir(PRODOS_ORDER if self.order == "prodos" else DOS_ORDER):
            return "ProDOS"
        return "unknown (own loader?)"

    # DOS 3.3

    def dos_files(self):
        vtoc = self.sector(17, 0)
        t, s = vtoc[1], vtoc[2]
        seen = set()
        while t and (t, s) not in seen:
            seen.add((t, s))
            c = self.sector(t, s)
            for i in range(7):
                e = c[0x0B + i * 35:0x0B + (i + 1) * 35]
                if e[0] in (0, 0xFF):
                    continue
                yield {"name": apple(e[3:33]).rstrip(), "type": DOS_TYPES.get(e[2] & 0x7F, "?"),
                       "locked": bool(e[2] & 0x80), "sectors": e[33] | e[34] << 8, "ts": (e[0], e[1])}
            t, s = c[1], c[2]

    def dos_read(self, f):
        data = b""
        t, s = f["ts"]
        seen = set()
        while t and (t, s) not in seen:
            seen.add((t, s))
            ts = self.sector(t, s)
            for i in range(122):
                dt, ds = ts[0x0C + 2 * i], ts[0x0D + 2 * i]
                data += self.sector(dt, ds) if dt or ds else bytes(256)
            t, s = ts[1], ts[2]
        data = data.rstrip(b"\0") if f["type"] == "T" else data
        if f["type"] in "IA":
            n = data[0] | data[1] << 8
            return data[2:2 + n], None
        if f["type"] == "B":
            address, n = data[0] | data[1] << 8, data[2] | data[3] << 8
            return data[4:4 + n], address
        return data, None

    # ProDOS

    def prodos_files(self, key=2, path=""):
        b, first = key, True
        while b:
            blk = self.block(b)
            for i in range(13):
                e = blk[4 + i * 0x27:4 + (i + 1) * 0x27]
                st, n = e[0] >> 4, e[0] & 0xF
                if (first and i == 0) or st == 0:
                    continue
                name = path + e[1:1 + n].decode("ascii", "replace")
                f = {"name": name, "type": PRODOS_TYPES.get(e[0x10], f"${e[0x10]:02X}"), "storage": st,
                     "key": e[0x11] | e[0x12] << 8, "blocks": e[0x13] | e[0x14] << 8,
                     "eof": e[0x15] | e[0x16] << 8 | e[0x17] << 16, "aux": e[0x1F] | e[0x20] << 8}
                yield f
                if st == 0xD:
                    yield from self.prodos_files(f["key"], name + "/")
            first = False
            b = blk[2] | blk[3] << 8

    def prodos_read(self, f):
        def index(b):
            i = self.block(b)
            return [i[k] | i[256 + k] << 8 for k in range(256)]

        st, key = f["storage"], f["key"]
        if st == 1:
            blocks = [key]
        elif st == 2:
            blocks = index(key)
        elif st == 3:
            blocks = [b for ib in index(key) if ib for b in index(ib)]
        else:
            sys.exit(f"{f['name']}: storage type {st} not supported")
        data = b"".join(self.block(b) if b else bytes(512) for b in blocks)
        return data[:f["eof"]], f["aux"] if f["type"] == "BIN" else None

    # either

    def files(self):
        return list(self.dos_files() if self.system() == "DOS 3.3" else self.prodos_files())

    def read(self, name):
        for f in self.files():
            if f["name"].upper() == name.upper():
                return f, (self.dos_read(f) if "ts" in f else self.prodos_read(f))
        sys.exit(f"{name}: not on {self.path.name}")


def applesoft(data, base=0x801):
    """An Applesoft program (tokenized lines) as text."""
    out, i = [], 0
    while i + 4 <= len(data):
        link = data[i] | data[i + 1] << 8
        if link == 0:
            break
        line = data[i + 2] | data[i + 3] << 8
        i += 4
        text = ""
        while i < len(data) and data[i]:
            c = data[i]
            text += f" {TOKENS[c - 0x80]} " if 0x80 <= c < 0xEB else chr(c) if c >= 0x20 else f"^{chr(c + 64)}"
            i += 1
        i += 1
        out.append(f"{line} {' '.join(text.split()) if 'REM' not in text and '\"' not in text else text.strip()}")
    return "\n".join(out)


def main(args):
    if len(args) < 2:
        sys.exit(__doc__)
    cmd = args[0]
    if cmd == "info":
        for p in args[1:]:
            d = Image(p)
            print(f"{d.path.name}: {d.order} order, {d.system()}")
        return
    d = Image(args[1])
    if cmd == "catalog":
        system = d.system()
        print(f"{d.path.name}: {system}, {d.order} order")
        for f in d.files():
            if "ts" in f:
                print(f"{'*' if f['locked'] else ' '}{f['type']} {f['sectors']:03} {f['name']}")
            else:
                print(f" {f['type']:<4} {f['blocks']:5} {f['eof']:7} ${f['aux']:04X} {f['name']}")
    elif cmd == "extract":
        f, (data, address) = d.read(args[2])
        # a binary's load address in its name, as CiderPress does: NAME#06XXXX.bin
        # (the emulator's Load Binary takes it from there)
        tag = f"#06{address:04X}" if address is not None else ""
        out = args[3] if len(args) > 3 else Path(f["name"]).name + tag + ".bin"
        Path(out).write_bytes(data)
        at = f" (load address ${address:04X})" if address is not None else ""
        print(f"{f['name']}: {len(data)} bytes{at} -> {out}")
    elif cmd == "list":
        f, (data, _) = d.read(args[2])
        print(applesoft(data))
    elif cmd == "sector":
        dump(d.sector(int(args[2], 0), int(args[3], 0)), 0, 256)
    elif cmd == "block":
        dump(d.block(int(args[2], 0)), 0, 512)
    elif cmd == "convert":
        to = PRODOS_ORDER if d.order == "dos" else DOS_ORDER
        out = bytearray(SIZE)
        for t in range(35):
            for p in range(16):
                o = t * 4096 + to[p] * 256
                out[o:o + 256] = d.physical(t, p)
        Path(args[2]).write_bytes(out)
        print(f"{d.path.name} ({d.order} order) -> {args[2]} ({'prodos' if d.order == 'dos' else 'dos'} order)")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
