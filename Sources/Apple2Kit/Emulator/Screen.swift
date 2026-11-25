import CoreGraphics
import Foundation
import MOS6502
import os

/// The Apple's display drawn from memory as it is at the moment (no beam:
/// a frame shows one mode), in the video's dots: 560 × 192, two dots a
/// pixel, RGBA (shown twice as high, 560:384):
///
/// * text: 40 × 24 characters from `Charset`, inverse below $40, flashing
///   $40-$7F (the ][ and ][+ have no lower case: $E0-$FF show as $A0-$BF;
///   the //e shows it, and with ALTCHARSET $40-$7F inverse, $60-$7F lower case,
///   the enhanced //e's $40-$5F MouseText);
///   the //e's 80 columns: aux and main memory's characters in turn;
/// * lo-res: 40 × 48 blocks in the 16 colours (the //e's double lo-res: 80 × 48);
/// * hi-res: 280 × 192 in one of the three `Style`s;
/// * the //e's double hi-res: 560 dots a line from aux and main memory in
///   the 16 colours, a colour a dot (`Style.color`) or as an RGB card
///   shows it (`Style.filled`: 140 × 192, 560 dots black and white or the
///   two mixed, `VideoMode.rgb`); on the monochrome screen the dots;
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
        /// palette bit set half a pixel to the right.  Double hi-res: each
        /// dot in the colour of the dots around it, its gaps dark too.
        case color = "Color"
        /// A colour's gaps filled in its colour, each pixel two dots where
        /// its column is, no byte shifted half a pixel.  Double hi-res: as an
        /// RGB card shows it on an RGB monitor (`VideoMode.rgb`).
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
    /// `Style.color`: a gap in a colour (an unlit pixel between two lit ones;
    /// in double hi-res an unlit dot) in the colour this much as bright – not quite black (it looks better than
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
    static let gapColours = hiresColours.map(shaded)
    /// Lo-res colours 0-15.
    static let loresColours: [UInt32] = [
        rgba(0, 0, 0), rgba(227, 30, 96), rgba(96, 78, 189), rgba(255, 68, 253),
        rgba(0, 163, 96), rgba(156, 156, 156), rgba(20, 207, 253), rgba(208, 195, 255),
        rgba(96, 114, 3), rgba(255, 106, 60), rgba(156, 156, 156), rgba(255, 160, 208),
        rgba(20, 245, 60), rgba(208, 221, 141), rgba(114, 255, 208), rgba(255, 255, 255),
    ]
    /// Lo-res colours 0-15 at `gapShade` (double hi-res's gaps in `Style.color`).
    static let loresGapColours = loresColours.map { shaded($0) }

    /// `c` (RGBA) at `gapShade`.
    static func shaded(_ c: UInt32) -> UInt32 {
        rgba(UInt8(Double(c & 0xFF) * gapShade), UInt8(Double(c >> 8 & 0xFF) * gapShade),
             UInt8(Double(c >> 16 & 0xFF) * gapShade))
    }

    // MARK: colour space

    /// The colour space the screen's images are made in (`image`, `images`,
    /// `thumbnail`, `Apple2Machine.screenImage`), its colours converted into
    /// it once (`Palette`): the colours above are sRGB.  An image in another
    /// space than the display's is converted pixel by pixel each time it is
    /// shown (Core Animation, on the CPU); a host that shows images often
    /// sets its display's (a Mac: its window's screen's `colorSpace`).  Each
    /// image is made in the space set as it starts, and says which.  Default
    /// device RGB, the colours as they are.
    public static var colorSpace: CGColorSpace {
        get { palette.space }
        set {
            let palette = Palette(newValue)
            current.withLock { $0 = palette }
        }
    }

    private static let current = OSAllocatedUnfairLock(initialState: Palette.device)

    /// The colours images are made in now (`colorSpace`).
    static var palette: Palette { current.withLock { $0 } }

    /// The screen's colours as RGBA in `space` (`colorSpace`).
    struct Palette: @unchecked Sendable {
        let space: CGColorSpace
        let black, white, green: UInt32
        let hires, gaps, lores, loresGaps: [UInt32]

        /// The colours as they are, in device RGB.
        static let device = Palette(space: CGColorSpaceCreateDeviceRGB()) { $0 }

        private init(space: CGColorSpace, _ convert: (UInt32) -> UInt32) {
            self.space = space
            (black, white, green) = (convert(Screen.black), convert(Screen.white), convert(Screen.green))
            hires = hiresColours.map(convert)
            gaps = gapColours.map(convert)
            lores = loresColours.map(convert)
            loresGaps = loresGapColours.map(convert)
        }

        /// The colours (sRGB) converted into `space` (an RGB space; device
        /// RGB, sRGB or another model: the colours as they are).
        init(_ space: CGColorSpace) {
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), space.model == .rgb,
                  !CFEqual(space, CGColorSpaceCreateDeviceRGB()), !CFEqual(space, srgb)
            else {
                self = Palette(space: space.model == .rgb ? space : CGColorSpaceCreateDeviceRGB()) { $0 }
                return
            }
            self = Palette(space: space) { c in
                let components = [c & 0xFF, c >> 8 & 0xFF, c >> 16 & 0xFF].map { CGFloat($0) / 255 } + [1]
                guard let colour = CGColor(colorSpace: srgb, components: components)?
                        .converted(to: space, intent: .defaultIntent, options: nil),
                      let k = colour.components, k.count >= 3
                else { return c }
                func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
                return rgba(byte(k[0]), byte(k[1]), byte(k[2]))
            }
        }
    }

    /// Text and lo-res row `row`'s first byte (page 1 at $0400, page 2 at $0800).
    @inline(__always) static func textAddress(row: Int, page2: Bool) -> Int {
        (page2 ? 0x800 : 0x400) + (row & 7) * 0x80 + (row >> 3) * 0x28
    }

    /// Hi-res line `y`'s first byte (page 1 at $2000, page 2 at $4000).
    @inline(__always) static func hiresAddress(line y: Int, page2: Bool) -> Int {
        (page2 ? 0x4000 : 0x2000) + (y & 7) * 0x400 + (y >> 3 & 7) * 0x80 + (y >> 6) * 0x28
    }

    /// Draws the display of `main` memory (and the //e's `aux` memory, 48K
    /// each) in `mode` into `pixels` (560 × 192).  `flash`: flashing
    /// characters show inverse now.  `lowercase`: the //e's character sets;
    /// `mouseText`: the enhanced //e's, MouseText at $40-$5F with ALTCHARSET.
    /// 80 columns, double lo-res and double hi-res need `aux`.
    static func render(_ main: UnsafePointer<UInt8>, aux: UnsafePointer<UInt8>? = nil, mode: VideoMode, flash: Bool,
                       lowercase: Bool = false, mouseText: Bool = false, style: Style, palette p: Palette,
                       into pixels: UnsafeMutableBufferPointer<UInt32>) {
        let out = pixels.baseAddress!
        let fg = style == .monochrome ? p.green : p.white
        let aux80 = mode.col80 ? aux : nil, double = mode.dhires ? aux80 : nil
        if mode.text {
            drawText(main, aux80, rows: 0 ..< 24, mode: mode, flash: flash, lowercase: lowercase, mouseText: mouseText,
                     fg: fg, bg: p.black, out)
            return
        }
        let split = mode.mixed ? 20 : 24
        switch (mode.hires, double) {
        case (true, nil): drawHires(main, lines: 0 ..< split * 8, page2: mode.page2, style: style, palette: p, out)
        case (true, let aux?):
            drawDoubleHires(main, aux, lines: 0 ..< split * 8, page2: mode.page2, style: style, rgb: mode.rgb,
                            palette: p, out)
        case (false, let aux): drawLores(main, aux, rows: 0 ..< split, page2: mode.page2, style: style, palette: p, out)
        }
        if mode.mixed {
            drawText(main, aux80, rows: 20 ..< 24, mode: mode, flash: flash, lowercase: lowercase, mouseText: mouseText,
                     fg: fg, bg: p.black, out)
        }
    }

    /// Text rows: 40 characters a row from `m`, each 14 dots wide; with `aux`
    /// (80 columns) 80, 7 dots each, aux memory's first.
    private static func drawText(_ m: UnsafePointer<UInt8>, _ aux: UnsafePointer<UInt8>?, rows: Range<Int>,
                                 mode: VideoMode, flash: Bool, lowercase: Bool, mouseText: Bool, fg: UInt32, bg: UInt32,
                                 _ out: UnsafeMutablePointer<UInt32>) {
        let columns = aux == nil ? 40 : 80, dots = aux == nil ? 2 : 1
        Charset.glyphs.withUnsafeBufferPointer { glyphs in
            for row in rows {
                let address = textAddress(row: row, page2: mode.page2)
                for column in 0 ..< columns {
                    let code = aux.map { column & 1 == 0 ? $0[address + column / 2] : m[address + column / 2] }
                        ?? m[address + column]
                    // $00-$1F and $40-$5F, $80-$9F, $C0-$DF are @A-Z[\]^_; the rest space to ?
                    let c = Int(code & 0x3F)
                    var glyph = (c < 0x20 ? c + 0x40 : c) - Charset.first
                    // the //e: lower case at $E0-$FF, and ALTCHARSET's at $60-$7F
                    if lowercase, code >= 0xE0 || (mode.altCharset && code & 0xE0 == 0x60) {
                        glyph = Int(code & 0x7F) - Charset.first
                    }
                    var inverse = code < 0x40 || (code < 0x80 && (flash || (lowercase && mode.altCharset)))
                    // the enhanced //e: ALTCHARSET's $40-$5F MouseText, drawn as it is
                    if mouseText, mode.altCharset, code & 0xE0 == 0x40 {
                        glyph = Charset.mouseText + Int(code & 0x1F)
                        inverse = false
                    }
                    for y in 0 ..< 8 {
                        let bits = glyphs[glyph * 8 + y]
                        let o = out + (row * 8 + y) * width + column * 7 * dots
                        for x in 0 ..< 7 {
                            let c = (bits >> x & 1 != 0) != inverse ? fg : bg
                            for d in 0 ..< dots { o[dots * x + d] = c }
                        }
                    }
                }
            }
        }
    }

    /// Lo-res rows: 40 blocks a row from `m`, 14 dots wide; with `aux`
    /// (double lo-res) 80, 7 dots each, aux memory's first, its colours
    /// rotated a bit to the left (the 7 dots it is ahead shift its colour's phase).
    private static func drawLores(_ m: UnsafePointer<UInt8>, _ aux: UnsafePointer<UInt8>?, rows: Range<Int>,
                                  page2: Bool, style: Style, palette p: Palette, _ out: UnsafeMutablePointer<UInt32>) {
        let blocks = aux == nil ? 40 : 80, dots = aux == nil ? 14 : 7
        for row in rows {
            let address = textAddress(row: row, page2: page2)
            for block in 0 ..< blocks {
                let fromAux = aux != nil && block & 1 == 0
                let byte = aux.map { fromAux ? $0[address + block / 2] : m[address + block / 2] } ?? m[address + block]
                for half in 0 ..< 2 {
                    var index = Int(half == 0 ? byte & 0xF : byte >> 4)
                    if fromAux { index = rotatedLeft(index) }
                    let colour = style != .monochrome ? p.lores[index] : index == 0 ? p.black : p.green
                    for y in 0 ..< 4 {
                        let o = out + (row * 8 + half * 4 + y) * width + block * dots
                        for x in 0 ..< dots { o[x] = colour }
                    }
                }
            }
        }
    }

    /// A 4-bit colour number rotated a bit to the left.
    @inline(__always) private static func rotatedLeft(_ n: Int) -> Int {
        (n << 1 & 0xF) | n >> 3
    }

    // MARK: double hi-res

    /// Double hi-res lines: each line's 560 dots from the 40 bytes of the
    /// line in aux and main memory in turn (aux first), 7 dots a byte, bit 0
    /// first.  A dot's place in the colour cycle gives it its bit of a lo-res
    /// colour: dot 0 bit 1, dot 1 bit 2, dot 2 bit 3, dot 3 bit 0 (mod 4) – as
    /// lo-res colours lie on the dots.
    ///
    /// * `Style.filled`: as an RGB card shows it on an RGB monitor, in its
    ///   mode (`rgb`): each 4 dots from the line's start a pixel of the
    ///   colour their bits make; or the dots in black and white; or mixed: a
    ///   byte with bit 7 set in colour, else its dots in black and white – a
    ///   colour pixel ends where a black and white byte starts, and the last
    ///   dot of a black and white byte lasts to the next pixel's start;
    /// * `Style.color`: as a composite monitor shows it, and as hi-res's
    ///   `Style.color`: each dot of the colour the 4 dots around it make (one
    ///   before, two after), so colours fringe where they meet; a lit dot in
    ///   it, an unlit one between lit ones (a gap) in a dark shade of it
    ///   (`gapShade`), any other black;
    /// * `Style.monochrome`: the dots.
    private static func drawDoubleHires(_ m: UnsafePointer<UInt8>, _ aux: UnsafePointer<UInt8>, lines: Range<Int>,
                                        page2: Bool, style: Style, rgb: VideoMode.RGBMode, palette p: Palette,
                                        _ out: UnsafeMutablePointer<UInt32>) {
        let (black, white, green) = (p.black, p.white, p.green)
        // the line's dots with 3 blank ones on either side
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: width + 6) { buffer in
            var colourByte = [Bool](repeating: true, count: 80)
            let dots = buffer.baseAddress! + 3
            for i in -3 ..< 0 { dots[i] = 0; dots[width - 1 - i] = 0 }
            p.lores.withUnsafeBufferPointer { colours in
                p.loresGaps.withUnsafeBufferPointer { gaps in
                    for y in lines {
                        let address = hiresAddress(line: y, page2: page2), o = out + y * width
                        for b in 0 ..< 80 {
                            let byte = b & 1 == 0 ? aux[address + b / 2] : m[address + b / 2]
                            for i in 0 ..< 7 { dots[b * 7 + i] = byte >> i & 1 }
                            colourByte[b] = rgb == .color || rgb == .mixed && byte & 0x80 != 0
                        }
                        switch style {
                        case .monochrome:
                            for d in 0 ..< width { o[d] = dots[d] != 0 ? green : black }
                        case .filled:
                            var last = black        // the last black and white dot
                            for d in 0 ..< width {
                                let x = d & ~3, start = d - d % 7
                                if !colourByte[d / 7] {
                                    last = dots[d] != 0 ? white : black
                                    o[d] = last
                                } else if x < start, !colourByte[d / 7 - 1] {
                                    o[d] = last     // a pixel begun in black and white
                                } else {
                                    let n = Int(dots[x] | dots[x + 1] << 1 | dots[x + 2] << 2 | dots[x + 3] << 3)
                                    o[d] = colours[rotatedLeft(n)]
                                }
                            }
                        case .color:
                            for d in 0 ..< width {
                                var n = 0
                                for i in d - 1 ... d + 2 { n |= Int(dots[i]) << ((i + 1) & 3) }
                                if dots[d] != 0 {
                                    o[d] = colours[n]
                                } else if dots[d - 1] | dots[d - 2] | dots[d - 3] != 0,
                                          dots[d + 1] | dots[d + 2] | dots[d + 3] != 0 {
                                    o[d] = gaps[n]
                                } else {
                                    o[d] = black
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: hi-res

    /// `screen` as the Apple shows it, in its dots: 560 × 384, a dot a
    /// column, a line two rows (`drawHires`).
    public static func image(_ screen: HiresScreen, style: Style = .color) -> CGImage? {
        image(screen, style: style, palette: palette)
    }

    private static func image(_ screen: HiresScreen, style: Style, palette p: Palette) -> CGImage? {
        let w = width
        var pixels = [UInt32](repeating: p.black, count: w * height * 2)
        pixels.withUnsafeMutableBufferPointer { buffer in
            screen.bytes.withUnsafeBufferPointer { bytes in
                withHiresLine(p) { line in
                    for y in 0 ..< height {
                        let o = buffer.baseAddress! + y * 2 * w
                        line.draw(bytes.baseAddress! + y * HiresScreen.bytesPerLine, style: style, into: o)
                        (o + w).update(from: o, count: w)
                    }
                }
            }
        }
        return image(pixels, width: w, height: height * 2, space: p.space)
    }

    /// The layers of `screen` (`HiresScreen.layers`) shown in `groups`
    /// (layer 0 always under them), each group as an image to show over the
    /// ones before it, and the lines it covers (top line first); nil:
    /// nothing of it shows.  `[0 ... 5, 6 ... 9]`: layers 0 to 5 in one
    /// image, 6 to 9 in another, something of the host's in between.
    ///
    /// The bytes of the layers shown make one page (`HiresScreen.showing`:
    /// a byte of a layer not shown has no pixels), drawn in its dots as
    /// `image` draws it: a pixel next to a lit one is white, whichever layer
    /// either is on.  Each byte's dots are in the image of its layer's group
    /// (a shifted byte's dots with it, `HiresScreen.dots`), black too; the
    /// other dots are transparent.  So the images over each other are that
    /// page.  A hidden dot (`HiresScreen.hidden`) is black in the page and
    /// transparent in the other groups' images, and so is a dot its layer
    /// passed through (`HiresScreen.passed`, as the page has it): the host's
    /// drawing between them shows there.  An image is 560 × 2·lines, from the group's first line with a
    /// dot to its last.  The group with layer 0 is opaque, the whole page:
    /// the dots of the groups over it in it too, which they cover (no seam
    /// where the host scales the images).
    public static func images(_ screen: HiresScreen, groups: [ClosedRange<Int>],
                              style: Style = .color) -> [(image: CGImage, lines: Range<Int>)?] {
        let page = screen.showing(groups), p = palette
        let baseLines = 0 ..< height
        let showsBase = groups.contains { $0.contains(0) }
        var overlays = groups.map { $0.contains(0) ? nil : HiresOverlay(screen, group: $0) }
        let overlayLines = overlays.compactMap { $0?.lines }
        guard let first = overlayLines.map(\.lowerBound).min(), let end = overlayLines.map(\.upperBound).max() else {
            let base = showsBase ? image(page, style: style, palette: p) : nil
            return groups.map { $0.contains(0) ? base.map { ($0, baseLines) } : nil }
        }

        let lines = showsBase ? baseLines : first ..< end
        let w = width, n = HiresScreen.bytesPerLine
        var basePixels = [UInt32](repeating: 0, count: showsBase ? w * height * 2 : 0)
        basePixels.withUnsafeMutableBufferPointer { base in
            page.bytes.withUnsafeBufferPointer { bytes in
                withHiresLine(p) { line in
                    withUnsafeTemporaryAllocation(of: UInt32.self, capacity: w) { scratch in
                        for y in lines {
                            let colours = showsBase ? base.baseAddress! + y * 2 * w : scratch.baseAddress!
                            line.draw(bytes.baseAddress! + y * n, style: style, into: colours)
                            if showsBase { (colours + w).update(from: colours, count: w) }
                            for index in overlays.indices {
                                overlays[index]?.writeLine(y, colours: colours, dots: line.dot, style: style)
                            }
                        }
                    }
                }
            }
        }

        let base = showsBase ? image(basePixels, width: w, height: height * 2, space: p.space) : nil
        return zip(groups, overlays).map { group, overlay in
            if group.contains(0) { return base.map { ($0, baseLines) } }
            guard let overlay else { return nil }
            return image(overlay.pixels, width: w, height: overlay.lines.count * 2, alpha: true, space: p.space).map { ($0, overlay.lines) }
        }
    }

    private struct HiresOverlay {
        let lines: Range<Int>
        /// Bits 0–6 are opaque pixels. Bit 7 records ownership of the byte
        /// for the black half-dot before a shifted first pixel of a line.
        let opacity: [UInt8]
        var pixels: [UInt32]

        init?(_ screen: HiresScreen, group: ClosedRange<Int>) {
            let n = HiresScreen.bytesPerLine
            var first = height, end = 0
            var opacity = [UInt8](repeating: 0, count: screen.layers.count)
            for byte in screen.layers.indices where group.contains(Int(screen.layers[byte])) {
                first = min(first, byte / n)
                end = byte / n + 1
                opacity[byte] = ~(screen.hidden[byte] | screen.passed[byte]) | 0x80
            }
            guard first < end else { return nil }
            lines = first ..< end
            self.opacity = opacity
            pixels = [UInt32](repeating: 0, count: width * lines.count * 2)
        }

        mutating func writeLine(_ y: Int, colours: UnsafePointer<UInt32>, dots: UnsafePointer<Int16>, style: Style) {
            guard lines.contains(y) else { return }
            let offset = (y - lines.lowerBound) * width * 2
            pixels.withUnsafeMutableBufferPointer { pixels in
                opacity.withUnsafeBufferPointer { opacity in
                    let out = pixels.baseAddress! + offset
                    let mask = opacity.baseAddress! + y * HiresScreen.bytesPerLine
                    for d in 0 ..< width {
                        let pixel = style == .filled ? d >> 1 : Int(dots[d])
                        let opaque = pixel >= 0 ? mask[pixel / 7] >> (pixel % 7) & 1 != 0 : mask[0] & 0x80 != 0
                        if opaque { out[d] = colours[d] }
                    }
                    (out + width).update(from: out, count: width)
                }
            }
        }
    }

    /// `screen` small, a pixel a pixel (280 × 192), for thumbnails: its
    /// colours as a colour monitor shows them from afar, filled in (as
    /// `Style.filled`; green on the monochrome screen).  Half a pixel is too
    /// small to show here: no byte shifted.
    public static func thumbnail(_ screen: HiresScreen, style: Style = .color) -> CGImage? {
        let w = HiresScreen.width, p = palette
        var pixels = [UInt32](repeating: p.black, count: w * height)
        pixels.withUnsafeMutableBufferPointer { buffer in
            screen.bytes.withUnsafeBufferPointer { bytes in
                withHiresLine(p) { line in
                    for y in 0 ..< height {
                        line.thumbnail(bytes.baseAddress! + y * HiresScreen.bytesPerLine, style: style,
                                       into: buffer.baseAddress! + y * w)
                    }
                }
            }
        }
        return image(pixels, width: w, height: height, space: p.space)
    }

    /// Hi-res lines of memory in their dots (`HiresLine.draw`).
    private static func drawHires(_ m: UnsafePointer<UInt8>, lines: Range<Int>, page2: Bool,
                                  style: Style, palette p: Palette, _ out: UnsafeMutablePointer<UInt32>) {
        withHiresLine(p) { line in
            for y in lines { line.draw(m + hiresAddress(line: y, page2: page2), style: style, into: out + y * width) }
        }
    }

    /// Runs `body` with room to draw hi-res lines in, in `p`'s colours.
    private static func withHiresLine<R>(_ p: Palette, _ body: (HiresLine) -> R) -> R {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: HiresScreen.width + 2) { px in
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: HiresScreen.width) { colours in
                withUnsafeTemporaryAllocation(of: Int16.self, capacity: width) { dots in
                    p.hires.withUnsafeBufferPointer { palette in
                        p.gaps.withUnsafeBufferPointer { gaps in
                            body(HiresLine(px: px.baseAddress!, colour: colours.baseAddress!, dot: dots.baseAddress!,
                                           palette: palette.baseAddress!, gaps: gaps.baseAddress!,
                                           black: p.black, white: p.white, green: p.green))
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
        let black, white, green: UInt32

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
    static func image(_ pixels: [UInt32], rowsTwice: Bool = false, space: CGColorSpace) -> CGImage? {
        guard rowsTwice else { return image(pixels, width: width, height: height, space: space) }
        var doubled = [UInt32](repeating: 0, count: pixels.count * 2)
        for y in 0 ..< height {
            doubled.replaceSubrange(2 * y * width ..< (2 * y + 1) * width, with: pixels[y * width ..< (y + 1) * width])
            doubled.replaceSubrange((2 * y + 1) * width ..< (2 * y + 2) * width, with: pixels[y * width ..< (y + 1) * width])
        }
        return image(doubled, width: width, height: height * 2, space: space)
    }

    /// `w` × `h` RGBA pixels in `space` as an image; with `alpha`, a pixel 0
    /// is transparent (the others are opaque).
    static func image(_ pixels: [UInt32], width w: Int, height h: Int, alpha: Bool = false,
                      space: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

nonisolated extension Apple2Machine {
    /// Characters flash about twice a second (every 16 frames).
    var flashOn: Bool { cpu.cycles / UInt64(Apple2Machine.cyclesPerFrame * 16) & 1 != 0 }

    /// The display now, 560 × 192 RGBA, in `palette`'s colours.
    func screenPixels(style: Screen.Style, palette: Screen.Palette = Screen.palette) -> [UInt32] {
        var pixels = [UInt32](repeating: palette.black, count: Screen.width * Screen.height)
        withMemory { main, aux in
            pixels.withUnsafeMutableBufferPointer { out in
                Screen.render(main, aux: aux, mode: displayMode, flash: flashOn, lowercase: isIIe,
                              mouseText: model == .apple2eEnhanced, style: style, palette: palette, into: out)
            }
        }
        return pixels
    }

    /// The display now: 560 × 192, or 560 × 384 with `rowsTwice`.
    public func screenImage(style: Screen.Style, rowsTwice: Bool = false) -> CGImage? {
        let palette = Screen.palette
        return Screen.image(screenPixels(style: style, palette: palette), rowsTwice: rowsTwice, space: palette.space)
    }

    /// Hi-res page 1 or 2 (`page2`; nil: the one shown) of main memory as a screen, with its bytes' layers.
    public func hiresScreen(page2: Bool? = nil) -> HiresScreen {
        let page2 = page2 ?? displayMode.page2
        return HiresScreen(ram(), base: page2 ? 0x4000 : 0x2000, layers: byteLayers, hidden: hiddenDots, passed: passedDots,
                           layersBase: page2 ? 0x2000 : 0)
    }

    /// The text page as text, 24 lines of 40 (the page shown, or page 1;
    /// 80 with the //e's 80 columns on), inverse and flashing as plain
    /// characters.
    public func screenText(page2: Bool? = nil) -> String {
        let main = ram(), aux = video.col80 ? ram(aux: true) : []
        return (0 ..< 24).map { row in
            let address = Screen.textAddress(row: row, page2: page2 ?? displayMode.page2)
            return String((0 ..< (aux.isEmpty ? 40 : 80)).map { column -> Character in
                let code = aux.isEmpty ? main[address + column]
                    : column & 1 == 0 ? aux[address + column / 2] : main[address + column / 2]
                if isIIe, code >= 0xE0 || (video.altCharset && code & 0xE0 == 0x60) {
                    return Character(Unicode.Scalar(code & 0x7F))
                }
                let c = Int(code & 0x3F)
                return Character(Unicode.Scalar(UInt8(c < 0x20 ? c + 0x40 : c)))
            })
        }.joined(separator: "\n")
    }
}
