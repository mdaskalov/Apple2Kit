#!/usr/bin/env python3
"""hexdump.py FILE START END [BASE]  -- hex dump with Apple (hi-bit) ASCII column."""
import sys


def dump(data, start, end, base=0, width=16):
    for a in range(start, end, width):
        row = data[a - base:a - base + width]
        txt = "".join(chr(c & 0x7F) if 0x20 <= (c & 0x7F) < 0x7F else "." for c in row)
        print(f"{a:04X}: {' '.join(f'{c:02X}' for c in row):<{width * 3}} {txt}")


if __name__ == "__main__":
    d = open(sys.argv[1], "rb").read()
    base = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0
    dump(d, int(sys.argv[2], 16), int(sys.argv[3], 16), base)
