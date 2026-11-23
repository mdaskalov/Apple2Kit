import MOS6502

// The shadow of the hi-res pages: a second copy of $2000-$5FFF of main
// memory, which the code's writes reach as they reach memory, byte for
// byte, but those of a native's code that ignores graphics
// (`NativeFlags.ignoresGraphics`, `addNative`).  A host shows it in place of
// the pages, and draws what its natives draw over it in its own way: the
// shadow is the page without their drawings, memory the page as the
// original code drew it.  Double hi-res (the //e's aux pages) has none: a
// write to aux memory doesn't reach it.

public nonisolated extension Apple2Machine {
    /// Its first address and its size: hi-res pages 1 and 2.
    static let shadowBase = 0x2000
    static let shadowSize = 0x4000
    internal static let shadowPages = 0x20 ..< 0x60

    /// The shadow's 16K, $2000-$5FFF (all zero while not `keepsShadow`).
    var shadow: [UInt8] { shadowBytes }

    /// Hi-res page 1 or 2 of the shadow (the page shown, as `hiresScreen`).
    func shadowScreen(page2: Bool? = nil) -> HiresScreen {
        HiresScreen(shadowBytes, base: page2 ?? displayMode.page2 ? 0x2000 : 0)
    }

    /// Writes `value` to the shadow at `address` ($2000-$5FFF), memory left
    /// as it is: a native drawing there what its code didn't.
    func writeShadow(_ address: Int, _ value: UInt8) {
        precondition(address >= Apple2Machine.shadowBase && address < Apple2Machine.shadowBase + Apple2Machine.shadowSize,
                     "the shadow is $2000-$5FFF")
        shadowBytes[address - Apple2Machine.shadowBase] = value
    }

    /// The shadow a copy of main memory's $2000-$5FFF again.
    func syncShadow() {
        for page in Apple2Machine.shadowPages {
            let a = page << 8, s = a - Apple2Machine.shadowBase
            if isIIe && isAuxInMemory(page) {
                shadowBytes.replaceSubrange(s ..< s + 0x100, with: mainBankPage(page))
            } else {
                shadowBytes.replaceSubrange(s ..< s + 0x100, with: cpu.mem[a ..< a + 0x100])
            }
        }
    }

    /// The CPU wrote `value` at `address`, on a watched page: to the
    /// shadow too, unless a native's code that ignores graphics runs.
    internal func shadowWrite(_ address: UInt16, _ value: UInt8) {
        let a = Int(address)
        guard keepsShadow, shadowSuspended == 0, Apple2Machine.shadowPages.contains(a >> 8),
              !(isIIe && isAuxInMemory(a >> 8)) else { return }
        shadowBytes[a - Apple2Machine.shadowBase] = value
        onShadowWrite?(a)
    }
}
