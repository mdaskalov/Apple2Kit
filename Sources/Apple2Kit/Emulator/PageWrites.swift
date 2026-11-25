import MOS6502

// The hi-res pages of main memory and the writes to them: a host following
// what the code draws there (`onPageWrite`), and each byte's layer
// (Layers.swift).  A native's code drawing on `.discard`
// (`NativeCall.run(into:)`) writes nothing there.  Double hi-res (the
// //e's aux pages) isn't followed: a write to aux memory isn't told, and
// its bytes have no layers.

public nonisolated extension Apple2Machine {
    /// Hi-res pages 1 and 2: their first address, size and memory pages.
    static let hiresBase = 0x2000
    static let hiresSize = 0x4000
    internal static let hiresPages = 0x20 ..< 0x60

    /// The CPU wrote `new` over `old` at `address`, on a watched page: the
    /// byte the current drawing's layer's (`DrawTarget`), told to
    /// `onPageWrite`.  The dots its code passed through as they were
    /// (`BitFlow`) stay what they were: a hidden layer's hidden
    /// (`hiddenDots(at:)`), and, on a layer over 0, the layers' under it
    /// (`passedDots(at:)`: while the byte stays the same layer's, only those
    /// it passed through every time).  A hidden layer's own dots are those it
    /// lights.
    internal func pageWritten(_ address: UInt16, old: UInt8, new: UInt8) {
        let a = Int(address)
        guard Apple2Machine.hiresPages.contains(a >> 8), !(isIIe && isAuxInMemory(a >> 8)) else { return }
        let offset = a - Apple2Machine.hiresBase
        let layerBefore = byteLayers[offset]
        byteLayers[offset] = drawLayer
        // The dots it stores as they were in the byte (and are: no write in between).
        let passed = flow.passed(at: a) & ~(old ^ new)
        if layerHidden[Int(drawLayer)] {
            hiddenDots[offset] = (hiddenDots[offset] | ~old) & new & 0x7F
            passedDots[offset] = 0
        } else {
            hiddenDots[offset] &= passed
            passedDots[offset] = drawLayer == 0 ? 0 : layerBefore == drawLayer ? passedDots[offset] & passed : passed
        }
        onPageWrite?(a)
    }
}
