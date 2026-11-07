import Foundation

/// A hi-res page's 8K as a screen: 192 lines of 40 bytes, top line first
/// (in memory the lines are interleaved: `lineOffset`).  Each byte holds 7
/// pixels, bit 0 leftmost, bit 7 the palette bit.  `Screen.image` and
/// `Screen.thumbnail` show it.
public nonisolated struct HiresScreen: Equatable, Sendable {
    public static let width = 280, height = 192, bytesPerLine = 40
    /// A line's dots on the screen: the video's 14 MHz dot clock, two a pixel.
    public static let dotsPerLine = 560

    /// Where each line (top line first) starts in a page's 8K, as in memory.
    public static let lineOffset: [Int] = (0 ..< height).map { $0 % 8 * 0x400 + $0 / 8 % 8 * 0x80 + $0 / 64 * 0x28 }

    public var bytes: [UInt8]

    /// A black screen.
    public init() {
        bytes = [UInt8](repeating: 0, count: HiresScreen.height * HiresScreen.bytesPerLine)
    }

    /// The page whose 8K lie in `memory` from `base` (page 1: $2000, page 2:
    /// $4000; 0 for a page's 8K alone).
    public init(_ memory: [UInt8], base: Int) {
        self.init()
        for line in 0 ..< HiresScreen.height {
            let address = base + HiresScreen.lineOffset[line]
            bytes.replaceSubrange(line * 40 ..< line * 40 + 40, with: memory[address ..< address + 40])
        }
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
