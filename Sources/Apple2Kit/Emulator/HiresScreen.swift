import Foundation

/// A hi-res page's 8K as a screen: 192 lines of 40 bytes, top line first
/// (in memory the lines are interleaved: `lineOffset`).  Each byte holds 7
/// pixels, bit 0 leftmost, bit 7 the palette bit, and its layer (the
/// drawing that wrote it, `DrawTarget`).  `Screen.image` and
/// `Screen.thumbnail` show it, `Screen.images` its layers in groups.
public nonisolated struct HiresScreen: Equatable, Sendable {
    public static let width = 280, height = 192, bytesPerLine = 40
    /// A line's dots on the screen: the video's 14 MHz dot clock, two a pixel.
    public static let dotsPerLine = 560

    /// Where each line (top line first) starts in a page's 8K, as in memory.
    public static let lineOffset: [Int] = (0 ..< height).map { $0 % 8 * 0x400 + $0 / 8 % 8 * 0x80 + $0 / 64 * 0x28 }

    public var bytes: [UInt8]
    /// Each byte's layer: 0 the code's own.
    public var layers: [UInt8]
    /// Each byte's dots (bits 0-6) a hidden layer lit
    /// (`Apple2Machine.hiddenLayers`): not shown.
    public var hidden: [UInt8]
    /// Each byte's dots (bits 0-6) its layer passed through as they were
    /// (`Apple2Machine.passedDots(at:)`): the layers under it show there.
    public var passed: [UInt8]

    /// A black screen, layer 0.
    public init() {
        bytes = [UInt8](repeating: 0, count: HiresScreen.height * HiresScreen.bytesPerLine)
        layers = bytes
        hidden = bytes
        passed = bytes
    }

    /// The page whose 8K lie in `memory` from `base` (page 1: $2000, page 2:
    /// $4000; 0 for a page's 8K alone), layer 0; its bytes' layers in
    /// `layers`, their hidden dots in `hidden` and the dots their layers passed
    /// through in `passed` from `layersBase`, when given.
    public init(_ memory: [UInt8], base: Int, layers: [UInt8]? = nil, hidden: [UInt8]? = nil, passed: [UInt8]? = nil,
                layersBase: Int = 0) {
        self.init()
        for line in 0 ..< HiresScreen.height {
            let address = base + HiresScreen.lineOffset[line], to = line * 40 ..< line * 40 + 40
            bytes.replaceSubrange(to, with: memory[address ..< address + 40])
            let from = layersBase + HiresScreen.lineOffset[line]
            if let layers { self.layers.replaceSubrange(to, with: layers[from ..< from + 40]) }
            if let hidden { self.hidden.replaceSubrange(to, with: hidden[from ..< from + 40]) }
            if let passed { self.passed.replaceSubrange(to, with: passed[from ..< from + 40]) }
        }
    }

    /// Whether a byte is another layer's than 0.
    public var hasLayers: Bool { layers.contains { $0 != 0 } }

    /// The bytes of the layers in `shown` (layer 0 always), the others 0 (no
    /// pixels), without their hidden dots: the page those layers make.
    public func showing(_ shown: [ClosedRange<Int>]) -> HiresScreen {
        var screen = self
        for i in layers.indices {
            if layers[i] != 0 && !shown.contains(where: { $0.contains(Int(layers[i])) }) {
                screen.bytes[i] = 0
            } else {
                screen.bytes[i] &= ~hidden[i]
            }
        }
        return screen
    }

    /// Which pixel of its line (0-279) each of a line's 560 dots shows, -1
    /// none (black), from the line's 40 bytes.  A byte's 7 pixels take the 14
    /// dots from its column's first (column × 14) on; a byte whose palette
    /// bit is set is shown one dot later, half a pixel to the right (the
    /// video loads it a 14 MHz clock late).  The dot that skips holds the
    /// dot before it (the previous byte's last pixel; nothing at the line's
    /// start), and the delayed byte's last pixel's second dot is the next
    /// byte's first, which a byte not delayed takes (off the line's end:
    /// lost).
    public static func dots(of line: UnsafePointer<UInt8>, into dots: UnsafeMutablePointer<Int16>) {
        for column in 0 ..< bytesPerLine {
            let first = column * 14, pixel = column * 7
            if line[column] & 0x80 == 0 {
                for d in 0 ..< 14 { dots[first + d] = Int16(pixel + d >> 1) }
            } else {
                dots[first] = column == 0 ? -1 : dots[first - 1]
                for d in 1 ... min(14, dotsPerLine - 1 - first) { dots[first + d] = Int16(pixel + (d - 1) >> 1) }
            }
        }
    }
}
