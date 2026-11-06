#!/usr/bin/env python3
"""Apple II hi-res helpers: address mapping and PNG rendering (no dependencies)."""
import struct
import sys
import zlib


def row_addr(y, base=0x2000):
    """Memory address of the first byte of hi-res scanline y (0..191)."""
    return base + (y & 7) * 0x400 + ((y >> 3) & 7) * 0x80 + (y >> 6) * 0x28


def write_png(path, width, height, rgb_rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rgb_rows)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


# NTSC-ish artifact colours: black, purple, green, white, blue, orange
BLACK, WHITE = (0, 0, 0), (255, 255, 255)
PURPLE, GREEN, BLUE, ORANGE = (255, 68, 253), (20, 245, 60), (20, 207, 253), (255, 106, 60)


def render(mem, base=0x2000, color=True, scale=2):
    """Render a hi-res page into rows of RGB bytes (280*scale x 192*scale)."""
    rows = []
    for y in range(192):
        a = row_addr(y, base)
        bits, hibit = [], []
        for x in range(40):
            b = mem[a + x]
            for i in range(7):
                bits.append((b >> i) & 1)
                hibit.append(b >> 7)
        line = []
        for x in range(280):
            if not bits[x]:
                c = BLACK
                if color and 0 < x < 279 and bits[x - 1] and bits[x + 1]:
                    c = _col(x - 1, hibit[x])
            elif (x > 0 and bits[x - 1]) or (x < 279 and bits[x + 1]):
                c = WHITE
            else:
                c = _col(x, hibit[x]) if color else WHITE
            line.extend(c * scale)
        for _ in range(scale):
            rows.append(line)
    return rows


def _col(x, hi):
    if hi:
        return BLUE if x % 2 == 0 else ORANGE
    return PURPLE if x % 2 == 0 else GREEN


if __name__ == "__main__":
    # hires.py MEM.bin OUT.png [base_hex]
    mem = open(sys.argv[1], "rb").read()
    base = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x2000
    write_png(sys.argv[2], 560, 384, render(mem, base))
