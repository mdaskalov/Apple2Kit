import CoreGraphics
import Foundation
import MOS6502

/// The Apple's display drawn from memory as it is at the moment (no beam:
/// a frame shows one mode), in the video's dots: 560 × 192, two dots a
/// pixel, RGBA (shown twice as high, 560:384):
///
/// * text: 40 × 24 characters from `Charset`, inverse below $40, flashing
///   $40-$7F (the ][ and ][+ have no lower case: $E0-$FF show as $A0-$BF;
///   the //e shows it, and with ALTCHARSET $40-$7F inverse, $60-$7F lower case);
/// * lo-res: 40 × 48 blocks in the 16 colours;
/// * hi-res: 280 × 192 in one of the three `Style`s;
/// * mixed: graphics with the text's last 4 lines.
///
/// Docs/Hardware.md has the memory layout.
public nonisolated enum Screen {
    /// Dots a line (the 14 MHz dot clock), lines.
    static let width = 560, height = 192

    /// How the screen is coloured.
    public enum Style: String, CaseIterable, Identifiable, Sendable {
        /// Each lit pixel in its colour: violet, green, blue, orange by
        /// palette bit and column, white next to another lit pixel; a gap in
        /// a colour in a dark shade of it (`gapShade`); a byte with the
        /// palette bit set half a pixel to the right.
        case color = "Color"
        /// A colour's gaps filled in its colour, each pixel two dots where
        /// its column is, no byte shifted half a pixel.
        case filled = "Color Filled"
        /// As on a green monochrome monitor (with the half-pixel shift).
        case monochrome = "Mono"
        public var id: String { rawValue }
    }

    /// RGBA as it lies in memory, R first, opaque.
    static func rgba(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
    }

    static let black = rgba(0, 0, 0)
    static let white = rgba(255, 255, 255)
    /// The monochrome screen's green.
    static let green = rgba(20, 245, 60)
    /// Hi-res: [palette bit × 2 + column parity]: violet, green, blue, orange.
    static let hiresRGB: [(UInt8, UInt8, UInt8)] = [(255, 68, 253), (20, 245, 60), (20, 207, 253), (255, 106, 60)]
    static let hiresColours = hiresRGB.map { rgba($0.0, $0.1, $0.2) }
    /// `Style.color`: a gap in a colour (an unlit pixel between two lit ones)
    /// in the colour this much as bright – not quite black (it looks better than
    /// black).
    static let gapShade = 0.4
    static let gapColours = hiresRGB.map {
        rgba(UInt8(Double($0.0) * gapShade), UInt8(Double($0.1) * gapShade), UInt8(Double($0.2) * gapShade))
    }
    /// Lo-res colours 0-15.
    static let loresColours: [UInt32] = [
        rgba(0, 0, 0), rgba(227, 30, 96), rgba(96, 78, 189), rgba(255, 68, 253),
        rgba(0, 163, 96), rgba(156, 156, 156), rgba(20, 207, 253), rgba(208, 195, 255),
        rgba(96, 114, 3), rgba(255, 106, 60), rgba(156, 156, 156), rgba(255, 160, 208),
        rgba(20, 245, 60), rgba(208, 221, 141), rgba(114, 255, 208), rgba(255, 255, 255),
    ]

    /// Text and lo-res row `row`'s first byte (page 1 at $0400, page 2 at $0800).
    @inline(__always) static func textAddress(row: Int, page2: Bool) -> Int {
        (page2 ? 0x800 : 0x400) + (row & 7) * 0x80 + (row >> 3) * 0x28
    }

    /// Hi-res line `y`'s first byte (page 1 at $2000, page 2 at $4000).
    @inline(__always) static func hiresAddress(line y: Int, page2: Bool) -> Int {
        (page2 ? 0x4000 : 0x2000) + (y & 7) * 0x400 + (y >> 3 & 7) * 0x80 + (y >> 6) * 0x28
    }

    /// Draws the display of `memory` (64K) in `mode` into `pixels` (560 × 192).
    /// `flash`: flashing characters show inverse now.  `lowercase`: the //e's
    /// character sets.
    static func render(_ memory: UnsafeBufferPointer<UInt8>, mode: VideoMode, flash: Bool, lowercase: Bool = false,
                       style: Style, into pixels: UnsafeMutableBufferPointer<UInt32>) {
        let m = memory.baseAddress!, out = pixels.baseAddress!
        let fg = style == .monochrome ? green : white
        if mode.text {
            drawText(m, rows: 0 ..< 24, mode: mode, flash: flash, lowercase: lowercase, fg: fg, out)
            return
        }
        let split = mode.mixed ? 20 : 24
        if mode.hires {
            drawHires(m, lines: 0 ..< split * 8, page2: mode.page2, style: style, out)
        } else {
            drawLores(m, rows: 0 ..< split, page2: mode.page2, style: style, out)
        }
        if mode.mixed { drawText(m, rows: 20 ..< 24, mode: mode, flash: flash, lowercase: lowercase, fg: fg, out) }
    }

    private static func drawText(_ m: UnsafePointer<UInt8>, rows: Range<Int>, mode: VideoMode, flash: Bool,
                                 lowercase: Bool, fg: UInt32, _ out: UnsafeMutablePointer<UInt32>) {
        Charset.glyphs.withUnsafeBufferPointer { glyphs in
            for row in rows {
                let address = textAddress(row: row, page2: mode.page2)
                for column in 0 ..< 40 {
                    let code = m[address + column]
                    // $00-$1F and $40-$5F, $80-$9F, $C0-$DF are @A-Z[\]^_; the rest space to ?
                    let c = Int(code & 0x3F)
                    var glyph = (c < 0x20 ? c + 0x40 : c) - Charset.first
                    // the //e: lower case at $E0-$FF, and ALTCHARSET's at $60-$7F
                    if lowercase, code >= 0xE0 || (mode.altCharset && code & 0xE0 == 0x60) {
                        glyph = Int(code & 0x7F) - Charset.first
                    }
                    let inverse = code < 0x40 || (code < 0x80 && (flash || (lowercase && mode.altCharset)))
                    for y in 0 ..< 8 {
                        let bits = glyphs[glyph * 8 + y]
                        let o = out + (row * 8 + y) * width + column * 14
                        for x in 0 ..< 7 {
                            let c = (bits >> x & 1 != 0) != inverse ? fg : black
                            o[2 * x] = c
                            o[2 * x + 1] = c
                        }
                    }
                }
            }
        }
    }

    private static func drawLores(_ m: UnsafePointer<UInt8>, rows: Range<Int>, page2: Bool,
                                  style: Style, _ out: UnsafeMutablePointer<UInt32>) {
        for row in rows {
            let address = textAddress(row: row, page2: page2)
            for column in 0 ..< 40 {
                let byte = m[address + column]
                for half in 0 ..< 2 {
                    let index = Int(half == 0 ? byte & 0xF : byte >> 4)
                    let colour = style != .monochrome ? loresColours[index] : index == 0 ? black : green
                    for y in 0 ..< 4 {
                        let o = out + (row * 8 + half * 4 + y) * width + column * 14
                        for x in 0 ..< 14 { o[x] = colour }
                    }
                }
            }
        }
    }

    // MARK: hi-res

    /// Hi-res lines in their dots.  A lit pixel's dots in its colour – white
    /// next to another lit pixel, else its palette colour; green on the
    /// monochrome screen –, a colour's gaps in a dark shade of it
    /// (`Style.color`), every other dot black; a byte with the palette bit
    /// set half a pixel to the right (`dots`).  `Style.filled`: gaps filled,
    /// nothing shifted.
    private static func drawHires(_ m: UnsafePointer<UInt8>, lines: Range<Int>, page2: Bool,
                                  style: Style, _ out: UnsafeMutablePointer<UInt32>) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 282) { line in
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 280) { colours in
                withUnsafeTemporaryAllocation(of: Int16.self, capacity: width) { dots in
                    hiresColours.withUnsafeBufferPointer { palette in
                        gapColours.withUnsafeBufferPointer { gaps in
                            let px = line.baseAddress!, colour = colours.baseAddress!, dot = dots.baseAddress!
                            let palette = palette.baseAddress!, gaps = gaps.baseAddress!
                            for y in lines {
                                let row = m + hiresAddress(line: y, page2: page2)
                                decode(row, into: px)
                                let o = out + y * width
                                switch style {
                                case .filled:
                                    for x in 0 ..< 280 {
                                        let c = filledColour(px, x, palette: palette, gaps: palette)
                                        o[2 * x] = c
                                        o[2 * x + 1] = c
                                    }
                                case .color, .monochrome:
                                    for x in 0 ..< 280 {
                                        colour[x] = style == .monochrome ? (px[x + 1] & 1 != 0 ? green : black)
                                            : filledColour(px, x, palette: palette, gaps: gaps)
                                    }
                                    hiresDots(of: row, into: dot)
                                    for d in 0 ..< width { o[d] = dot[d] >= 0 ? colour[Int(dot[d])] : black }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Pixel `x`'s colour filled in, as a colour monitor shows a colour's
    /// pixels from afar: a lit pixel white next to another lit pixel, else
    /// its palette colour; an unlit one between two lit ones – a gap in a
    /// colour – the colour they make, from `gaps`; any other black.  `px` as
    /// `decode` leaves it.
    @inline(__always)
    private static func filledColour(_ px: UnsafeMutablePointer<UInt8>, _ x: Int,
                                     palette: UnsafePointer<UInt32>, gaps: UnsafePointer<UInt32>) -> UInt32 {
        let p = px[x + 1], left = px[x], right = px[x + 2]
        if p & 1 != 0 { return (left | right) & 1 != 0 ? white : palette[Int(p & 2) + (x & 1)] }
        if left & right & 1 != 0 { return gaps[Int(p & 2) + ((x - 1) & 1)] }
        return black
    }

    /// A line's pixels into `px` with a blank one on either side (282): bit 0
    /// on, bit 1 the palette bit.
    @inline(__always)
    private static func decode(_ row: UnsafePointer<UInt8>, into px: UnsafeMutablePointer<UInt8>) {
        px[0] = 0
        px[281] = 0
        for b in 0 ..< 40 {
            let v = row[b], pal = v >> 6 & 2
            for i in 0 ..< 7 { px[1 + b * 7 + i] = v >> i & 1 | pal }
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
    static func hiresDots(of line: UnsafePointer<UInt8>, into dots: UnsafeMutablePointer<Int16>) {
        for column in 0 ..< 40 {
            let first = column * 14, pixel = column * 7
            if line[column] & 0x80 == 0 {
                for d in 0 ..< 14 { dots[first + d] = Int16(pixel + d >> 1) }
            } else {
                dots[first] = column == 0 ? -1 : dots[first - 1]
                for d in 1 ... min(14, width - 1 - first) { dots[first + d] = Int16(pixel + (d - 1) >> 1) }
            }
        }
    }

    /// 560 × 192 RGBA pixels as an image (`rowsTwice`: 560 × 384, each line twice).
    static func image(_ pixels: [UInt32], rowsTwice: Bool = false) -> CGImage? {
        var data = pixels.withUnsafeBytes { Data($0) }
        if rowsTwice {
            let line = width * 4
            var doubled = Data(capacity: data.count * 2)
            for y in 0 ..< height {
                let row = data[y * line ..< (y + 1) * line]
                doubled.append(row)
                doubled.append(row)
            }
            data = doubled
        }
        let h = rowsTwice ? height * 2 : height
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

nonisolated extension Apple2 {
    /// Characters flash about twice a second (every 16 frames).
    var flashOn: Bool { cpu.cycles / UInt64(Apple2.cyclesPerFrame * 16) & 1 != 0 }

    /// The display now, 560 × 192 RGBA.
    func screenPixels(style: Screen.Style) -> [UInt32] {
        var pixels = [UInt32](repeating: Screen.black, count: Screen.width * Screen.height)
        cpu.mem.withUnsafeBufferPointer { memory in
            pixels.withUnsafeMutableBufferPointer { out in
                Screen.render(memory, mode: video, flash: flashOn, lowercase: isIIe, style: style, into: out)
            }
        }
        return pixels
    }

    /// The display now: 560 × 192, or 560 × 384 with `rowsTwice`.
    public func screenImage(style: Screen.Style, rowsTwice: Bool = false) -> CGImage? {
        Screen.image(screenPixels(style: style), rowsTwice: rowsTwice)
    }

    /// The text page as text, 24 lines of 40 (the page shown, or page 1),
    /// inverse and flashing as plain characters.
    public func screenText(page2: Bool? = nil) -> String {
        (0 ..< 24).map { row in
            let address = Screen.textAddress(row: row, page2: page2 ?? video.page2)
            return String((0 ..< 40).map { column -> Character in
                let code = cpu.mem[address + column]
                if isIIe, code >= 0xE0 || (video.altCharset && code & 0xE0 == 0x60) {
                    return Character(Unicode.Scalar(code & 0x7F))
                }
                let c = Int(code & 0x3F)
                return Character(Unicode.Scalar(UInt8(c < 0x20 ? c + 0x40 : c)))
            })
        }.joined(separator: "\n")
    }
}
