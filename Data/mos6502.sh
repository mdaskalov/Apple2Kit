# Sourced by the scripts that build Swift (from Data/): compiles the MOS6502
# package (https://github.com/mdaskalov/MOS6502) into a module and a static
# library and sets MOS6502 to the swiftc flags that use it.
# The sources: $MOS6502_PACKAGE if set (a local working copy), otherwise a
# clone of $MOS6502_REF (a tag or branch, default 1.0.0, as in Package.swift)
# kept in $TMPDIR.
MOS6502_URL="https://github.com/mdaskalov/MOS6502.git"
MOS6502_REF="${MOS6502_REF:-1.0.0}"
MOS6502_OUT="${TMPDIR:-/tmp}/apple2kit_mos6502"
mkdir -p "$MOS6502_OUT"
if [ -z "$MOS6502_PACKAGE" ]; then
    MOS6502_PACKAGE="$MOS6502_OUT/src-$MOS6502_REF"
    if [ ! -d "$MOS6502_PACKAGE/.git" ]; then
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$MOS6502_REF" "$MOS6502_URL" "$MOS6502_PACKAGE"
    elif ! git -C "$MOS6502_PACKAGE" describe --tags --exact-match >/dev/null 2>&1; then
        # a branch (e.g. main): bring it up to date
        git -C "$MOS6502_PACKAGE" pull --quiet --ff-only
    fi
fi
swiftc -O -wmo -parse-as-library -cross-module-optimization -module-name MOS6502 \
    -emit-module -emit-module-path "$MOS6502_OUT/MOS6502.swiftmodule" \
    -emit-library -static -o "$MOS6502_OUT/libMOS6502.a" "$MOS6502_PACKAGE"/Sources/MOS6502/*.swift
MOS6502="-I $MOS6502_OUT -L $MOS6502_OUT -lMOS6502"
