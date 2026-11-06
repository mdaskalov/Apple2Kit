#!/bin/sh
# Builds headless.swift with the emulator core (Sources/Apple2Kit/Emulator) and
# runs it.  Usage: ./headless.sh [--model plus|ii|e] ACTION...  (Data/README.md)
# Paths are taken from Data/.
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/apple2kit_headless"
. ./mos6502.sh
swiftc -O -wmo -parse-as-library $MOS6502 -o "$OUT" headless.swift ../Sources/Apple2Kit/Emulator/*.swift
"$OUT" "$@"
