#!/usr/bin/env python3
"""Extract the Apple II text font from a bitmap font into Swift.

Usage: charset.py FONT OUT.swift [PREVIEW.png]

FONT is a .bff file, Codehead's Bitmap Font Generator's:
a 20-byte header (BF F2, image width, height, cell width, cell height as
little-endian 32-bit words, bits per pixel, first character), 256 character
widths, then the RGB image, top row first.  Its cells are 14 x 16 pixels, the
Apple's 7 x 8 dots doubled, cell i = ASCII $20 + i, 18 cells a row.

FONT may also be a Charset.swift this script wrote: its ASCII glyphs are
read back, so the file can be made again without the font.

Writes the 96 glyphs of ASCII $20-$7F, then the enhanced //e's 32 MouseText
glyphs (below, $40-$5F with ALTCHARSET), as 8 rows of 7 bits each
(bit 0 the leftmost dot, row 0 the top), the layout of the Apple's hi-res
bytes, as the Swift array `Charset.glyphs` (128 * 8 bytes).  Checks that every
2 x 2 block of the cell is one colour, so nothing is lost by taking every
second pixel.
"""
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hires import write_png  # noqa: E402

FIRST, COUNT = 0x20, 96

# MouseText $40-$5F as the enhanced //e's video ROM has it (its dots
# inverted: as shown), '#' a lit dot, the leftmost first.
MOUSETEXT = [
    ("closed apple", """
....#..
...#...
.##.##.
#######
######.
######.
.######
.##.##."""),
    ("open apple", """
....#..
...#...
.##.##.
#.....#
#....#.
#....#.
.#.#..#
.##.##."""),
    ("pointer", """
.......
.......
.#.....
.##....
.###...
.####..
.##.##.
.#....#"""),
    ("hourglass", """
#######
.#...#.
..#.#..
...#...
...#...
..#.#..
.#.#.#.
#######"""),
    ("check mark", """
.......
......#
.....#.
#...#..
.#.#...
..#....
..#....
......."""),
    ("inverse check mark", """
#######
######.
#####.#
..##.##
#.#.###
##.####
##.####
#######"""),
    ("running man (left)", """
....###
.....##
.######
#...##.
#..####
....##.
######.
.#....."""),
    ("running man (right)", """
.......
...##..
###....
.......
###....
..##...
...#...
....###"""),
    ("left arrow", """
...#...
..#....
.#.....
#######
.#.....
..#....
...#...
......."""),
    ("ellipsis", """
.......
.......
.......
.......
.......
.......
.......
.#.#.#."""),
    ("down arrow", """
...#...
...#...
...#...
...#...
#..#..#
.#.#.#.
..###..
...#..."""),
    ("up arrow", """
...#...
..###..
.#.#.#.
#..#..#
...#...
...#...
...#...
...#..."""),
    ("overbar", """
#######
.......
.......
.......
.......
.......
.......
......."""),
    ("return", """
......#
......#
......#
..#...#
.##...#
#######
.##....
..#...."""),
    ("block", """
######.
######.
######.
######.
######.
######.
######.
######."""),
    ("scroll left", """
##..#..
...##..
..###..
.######
..###..
...##..
....#..
####.##"""),
    ("scroll right", """
..#..##
..##...
..###..
######.
..###..
..##...
..#....
##.####"""),
    ("scroll down", """
......#
...#..#
...#...
#######
.#####.
..###..
...#..#
......#"""),
    ("scroll up", """
......#
...#..#
..###..
.#####.
#######
...#...
...#..#
......#"""),
    ("horizontal line", """
.......
.......
.......
#######
.......
.......
.......
......."""),
    ("lower left corner", """
#......
#......
#......
#......
#......
#......
#......
#######"""),
    ("right arrow", """
...#...
....#..
.....#.
#######
.....#.
....#..
...#...
......."""),
    ("checkerboard", """
.#.#.#.
#.#.#.#
.#.#.#.
#.#.#.#
.#.#.#.
#.#.#.#
.#.#.#.
#.#.#.#"""),
    ("checkerboard 2", """
#.#.#.#
.#.#.#.
#.#.#.#
.#.#.#.
#.#.#.#
.#.#.#.
#.#.#.#
.#.#.#."""),
    ("folder (left)", """
.......
.#####.
#.....#
#......
#......
#......
#######
......."""),
    ("folder (right)", """
.......
.......
######.
......#
......#
......#
#######
......."""),
    ("right vertical line", """
......#
......#
......#
......#
......#
......#
......#
......#"""),
    ("diamond", """
...#...
..###..
.#####.
#######
.#####.
..###..
...#...
......."""),
    ("top and bottom lines", """
#######
.......
.......
.......
.......
.......
.......
#######"""),
    ("grid", """
..#.#..
..#.#..
###.###
.......
###.###
..#.#..
..#.#..
......."""),
    ("box right side, dot", """
#######
......#
......#
..##..#
..##..#
......#
......#
#######"""),
    ("left vertical line", """
#......
#......
#......
#......
#......
#......
#......
#......"""),
]


def mousetext():
    """The 32 MouseText glyphs and their names."""
    glyphs = [[sum(1 << c for c, ch in enumerate(line) if ch == "#") for line in art.strip().splitlines()]
              for _, art in MOUSETEXT]
    assert len(glyphs) == 32 and all(len(g) == 8 for g in glyphs)
    return glyphs, [name for name, _ in MOUSETEXT]


def glyphs(path):
    if path.endswith(".swift"):
        lines = [ln for ln in Path(path).read_text().splitlines() if re.search(r"// \$[2-7]", ln)]
        return [[int(x, 16) for x in re.findall(r"0x([0-9A-F]{2})", ln)] for ln in lines]
    d = Path(path).read_bytes()
    if d[:2] != b"\xbf\xf2":
        sys.exit(f"{path}: not a BFF font")
    w, h, cw, ch = struct.unpack("<IIII", d[2:18])
    bpp, base = d[18], d[19]
    if (cw, ch, bpp, base) != (14, 16, 24, FIRST):
        sys.exit(f"{path}: expected 14x16 cells, 24 bpp, first char $20 (got {cw}x{ch}, {bpp}, ${base:02X})")
    px = d[276:]
    per_row = w // cw

    def lit(x, y):
        return px[(y * w + x) * 3] > 127

    out = []
    for i in range(COUNT):
        cy, cx = divmod(i, per_row)
        x0, y0 = cx * cw, cy * ch
        rows = []
        for r in range(8):
            v = 0
            for c in range(7):
                block = {lit(x0 + 2 * c + dx, y0 + 2 * r + dy) for dx in (0, 1) for dy in (0, 1)}
                if len(block) != 1:
                    sys.exit(f"char ${FIRST + i:02X}: dot {c},{r} is not a 2x2 block")
                if block.pop():
                    v |= 1 << c
            rows.append(v)
        out.append(rows)
    return out


def write_swift(path, gl):
    mt, names = mousetext()
    lines = [
        "// Generated by Data/charset.py -- do not edit.",
        "",
        "/// The Apple II text font: ASCII $20-$7F, then the enhanced //e's MouseText",
        "/// ($40-$5F with ALTCHARSET) from glyph `mouseText` on; 8 rows of 7 dots per",
        "/// character, row 0 the top, bit 0 the leftmost dot (as in the hi-res bytes).",
        "nonisolated enum Charset {",
        "    static let first = 0x20",
        f"    static let mouseText = {COUNT}",
        "    static let glyphs: [UInt8] = [",
    ]
    for i, rows in enumerate(gl):
        ch = chr(FIRST + i)
        label = {"\\": "backslash", " ": "space"}.get(ch, ch)
        lines.append("        " + ", ".join(f"0x{r:02X}" for r in rows) + f",  // ${FIRST + i:02X} {label}")
    for i, (rows, name) in enumerate(zip(mt, names)):
        lines.append("        " + ", ".join(f"0x{r:02X}" for r in rows) + f",  // MouseText ${0x40 + i:02X} {name}")
    lines += ["    ]", "}", ""]
    Path(path).write_text("\n".join(lines))


def write_preview(path, gl, scale=3):
    """16 characters a row, 8 rows (MouseText the last 2), 1 dot of space around each."""
    gl = gl + mousetext()[0]
    cols, rows = 16, len(gl) // 16
    w, h = cols * 9 * scale, rows * 10 * scale
    img = [[(0, 0, 0)] * w for _ in range(h)]
    for i, g in enumerate(gl):
        gx, gy = (i % cols) * 9 + 1, (i // cols) * 10 + 1
        for r in range(8):
            for c in range(7):
                if g[r] >> c & 1:
                    for sy in range(scale):
                        for sx in range(scale):
                            img[(gy + r) * scale + sy][(gx + c) * scale + sx] = (255, 255, 255)
    write_png(path, w, h, [[v for p in row for v in p] for row in img])


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    gl = glyphs(sys.argv[1])
    write_swift(sys.argv[2], gl)
    if len(sys.argv) > 3:
        write_preview(sys.argv[3], gl)
    print(f"{len(gl)} glyphs + 32 MouseText -> {sys.argv[2]}")
