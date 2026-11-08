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

    /// A colour of the screen.
    public struct RGB: Equatable, Sendable {
        public let r, g, b: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }
    }

    public static let whiteRGB = RGB(r: 255, g: 255, b: 255)
    /// The monochrome screen's green.
    public static let monoRGB = RGB(r: 20, g: 245, b: 60)
    /// Hi-res: [palette bit × 2 + column parity]: violet, green, blue, orange.
    public static let hiresRGB = [RGB(r: 255, g: 68, b: 253), RGB(r: 20, g: 245, b: 60),
                                  RGB(r: 20, g: 207, b: 253), RGB(r: 255, g: 106, b: 60)]
    /// `Style.color`: a gap in a colour (an unlit pixel between two lit ones)
    /// in the colour this much as bright – not quite black (it looks better than
    /// black).
    public static let gapShade = 0.4

    /// RGBA as it lies in memory, R first, opaque.
    static func rgba(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
    }

    static func rgba(_ c: RGB) -> UInt32 { rgba(c.r, c.g, c.b) }

    static let black = rgba(0, 0, 0)
    static let white = rgba(whiteRGB)
    static let green = rgba(monoRGB)
    static let hiresColours = hiresRGB.map(rgba)
    static let gapColours = hiresRGB.map {
        rgba(UInt8(Double($0.r) * gapShade), UInt8(Double($0.g) * gapShade), UInt8(Double($0.b) * gapShade))
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

    /// `screen` as the Apple shows it, in its dots: 560 × 384, a dot a
    /// column, a line two rows (`drawHires`).
    public static func image(_ screen: HiresScreen, style: Style = .color) -> CGImage? {
        let w = width
        var pixels = [UInt32](repeating: black, count: w * height * 2)
        pixels.withUnsafeMutableBufferPointer { buffer in
            screen.bytes.withUnsafeBufferPointer { bytes in
                withHiresLine { line in
                    for y in 0 ..< height {
                        let o = buffer.baseAddress! + y * 2 * w
                        line.draw(bytes.baseAddress! + y * HiresScreen.bytesPerLine, style: style, into: o)
                        (o + w).update(from: o, count: w)
                    }
                }
            }
        }
        return image(pixels, width: w, height: height * 2)
    }

    /// `screen` small, a pixel a pixel (280 × 192), for thumbnails: its
    /// colours as a colour monitor shows them from afar, filled in (as
    /// `Style.filled`; green on the monochrome screen).  Half a pixel is too
    /// small to show here: no byte shifted.
    public static func thumbnail(_ screen: HiresScreen, style: Style = .color) -> CGImage? {
        let w = HiresScreen.width
        var pixels = [UInt32](repeating: black, count: w * height)
        pixels.withUnsafeMutableBufferPointer { buffer in
            screen.bytes.withUnsafeBufferPointer { bytes in
                withHiresLine { line in
                    for y in 0 ..< height {
                        line.thumbnail(bytes.baseAddress! + y * HiresScreen.bytesPerLine, style: style,
                                       into: buffer.baseAddress! + y * w)
                    }
                }
            }
        }
        return image(pixels, width: w, height: height)
    }

    /// Hi-res lines of memory in their dots (`HiresLine.draw`).
    private static func drawHires(_ m: UnsafePointer<UInt8>, lines: Range<Int>, page2: Bool,
                                  style: Style, _ out: UnsafeMutablePointer<UInt32>) {
        withHiresLine { line in
            for y in lines { line.draw(m + hiresAddress(line: y, page2: page2), style: style, into: out + y * width) }
        }
    }

    /// Runs `body` with room to draw hi-res lines in.
    private static func withHiresLine<R>(_ body: (HiresLine) -> R) -> R {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: HiresScreen.width + 2) { px in
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: HiresScreen.width) { colours in
                withUnsafeTemporaryAllocation(of: Int16.self, capacity: width) { dots in
                    hiresColours.withUnsafeBufferPointer { palette in
                        gapColours.withUnsafeBufferPointer { gaps in
                            body(HiresLine(px: px.baseAddress!, colour: colours.baseAddress!, dot: dots.baseAddress!,
                                           palette: palette.baseAddress!, gaps: gaps.baseAddress!))
                        }
                    }
                }
            }
        }
    }

    /// Draws a hi-res line, from its 40 bytes, in room it doesn't allocate:
    /// runs on every frame shown, so on pointers (a Debug build's array
    /// checks made a screen take 40 ms).
    private struct HiresLine {
        /// The line's pixels with a blank one on either side (282): bit 0
        /// on, bit 1 the palette bit (`decode`).
        let px: UnsafeMutablePointer<UInt8>
        /// Each pixel's colour (280).
        let colour: UnsafeMutablePointer<UInt32>
        /// Each dot's pixel (560, `HiresScreen.dots`).
        let dot: UnsafeMutablePointer<Int16>
        let palette: UnsafePointer<UInt32>
        let gaps: UnsafePointer<UInt32>

        /// The line in its 560 dots.  A lit pixel's dots in its colour –
        /// white next to another lit pixel, else its palette colour; green on
        /// the monochrome screen –, a colour's gaps in a dark shade of it
        /// (`Style.color`), every other dot black; a byte with the palette
        /// bit set half a pixel to the right (`HiresScreen.dots`).
        /// `Style.filled`: gaps filled, nothing shifted.
        @inline(__always)
        func draw(_ row: UnsafePointer<UInt8>, style: Style, into o: UnsafeMutablePointer<UInt32>) {
            decode(row)
            switch style {
            case .filled:
                for x in 0 ..< HiresScreen.width {
                    let c = filledColour(x, gaps: palette)
                    o[2 * x] = c
                    o[2 * x + 1] = c
                }
            case .color, .monochrome:
                for x in 0 ..< HiresScreen.width {
                    colour[x] = style == .monochrome ? (px[x + 1] & 1 != 0 ? green : black) : filledColour(x, gaps: gaps)
                }
                HiresScreen.dots(of: row, into: dot)
                for d in 0 ..< width { o[d] = dot[d] >= 0 ? colour[Int(dot[d])] : black }
            }
        }

        /// The line a pixel a pixel (280), filled in.
        @inline(__always)
        func thumbnail(_ row: UnsafePointer<UInt8>, style: Style, into o: UnsafeMutablePointer<UInt32>) {
            decode(row)
            for x in 0 ..< HiresScreen.width {
                o[x] = style == .monochrome ? (px[x + 1] & 1 != 0 ? green : black) : filledColour(x, gaps: palette)
            }
        }

        /// Pixel `x`'s colour filled in, as a colour monitor shows a colour's
        /// pixels from afar: a lit pixel white next to another lit pixel, else
        /// its palette colour; an unlit one between two lit ones – a gap in a
        /// colour – the colour they make, from `gaps`; any other black.
        @inline(__always)
        private func filledColour(_ x: Int, gaps: UnsafePointer<UInt32>) -> UInt32 {
            let p = px[x + 1], left = px[x], right = px[x + 2]
            if p & 1 != 0 { return (left | right) & 1 != 0 ? white : palette[Int(p & 2) + (x & 1)] }
            if left & right & 1 != 0 { return gaps[Int(p & 2) + ((x - 1) & 1)] }
            return black
        }

        @inline(__always)
        private func decode(_ row: UnsafePointer<UInt8>) {
            px[0] = 0
            px[HiresScreen.width + 1] = 0
            for b in 0 ..< HiresScreen.bytesPerLine {
                let v = row[b], pal = v >> 6 & 2
                for i in 0 ..< 7 { px[1 + b * 7 + i] = v >> i & 1 | pal }
            }
        }
    }

    /// 560 × 192 RGBA pixels as an image (`rowsTwice`: 560 × 384, each line twice).
    static func image(_ pixels: [UInt32], rowsTwice: Bool = false) -> CGImage? {
        guard rowsTwice else { return image(pixels, width: width, height: height) }
        var doubled = [UInt32](repeating: 0, count: pixels.count * 2)
        for y in 0 ..< height {
            doubled.replaceSubrange(2 * y * width ..< (2 * y + 1) * width, with: pixels[y * width ..< (y + 1) * width])
            doubled.replaceSubrange((2 * y + 1) * width ..< (2 * y + 2) * width, with: pixels[y * width ..< (y + 1) * width])
        }
        return image(doubled, width: width, height: height * 2)
    }

    /// `w` × `h` RGBA pixels as an image.
    static func image(_ pixels: [UInt32], width w: Int, height h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

nonisolated extension Apple2Machine {
    /// Characters flash about twice a second (every 16 frames).
    var flashOn: Bool { cpu.cycles / UInt64(Apple2Machine.cyclesPerFrame * 16) & 1 != 0 }

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

    /// Hi-res page 1 or 2 (`page2`; nil: the one shown) as a screen.
    public func hiresScreen(page2: Bool? = nil) -> HiresScreen {
        HiresScreen(cpu.mem, base: page2 ?? video.page2 ? 0x4000 : 0x2000)
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
