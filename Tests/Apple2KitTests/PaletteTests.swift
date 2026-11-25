import CoreGraphics
import Testing
@testable import Apple2Kit

/// The screen's colours in a colour space (`Screen.colorSpace`, `Screen.Palette`).
@Suite struct PaletteTests {
    /// Device RGB and sRGB: the colours as they are.
    @Test func asTheyAre() {
        for space in [CGColorSpaceCreateDeviceRGB(), CGColorSpace(name: CGColorSpace.sRGB)!] {
            let p = Screen.Palette(space)
            #expect(p.black == Screen.black && p.white == Screen.white && p.green == Screen.green)
            #expect(p.hires == Screen.hiresColours && p.gaps == Screen.gapColours)
            #expect(p.lores == Screen.loresColours && p.loresGaps == Screen.loresGapColours)
            #expect(CFEqual(p.space, space))
        }
    }

    /// Display P3: the same colours, converted (black and white stay, the
    /// others less saturated), and back in sRGB within two steps (a byte a
    /// channel in P3: green's red, 20, comes back 22).
    @Test func displayP3() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let p = Screen.Palette(p3)
        #expect(p.black == Screen.black && p.white == Screen.white)
        #expect(p.green != Screen.green && p.hires != Screen.hiresColours)
        func channels(_ c: UInt32) -> [Int] { [Int(c & 0xFF), Int(c >> 8 & 0xFF), Int(c >> 16 & 0xFF)] }
        for (converted, original) in zip(p.hires + p.lores, Screen.hiresColours + Screen.loresColours) {
            #expect(converted >> 24 == 0xFF)
            let colour = try #require(CGColor(colorSpace: p3, components: channels(converted).map { CGFloat($0) / 255 } + [1])?
                .converted(to: srgb, intent: .defaultIntent, options: nil)?.components)
            let back = colour.prefix(3).map { Int(($0 * 255).rounded()) }
            #expect(zip(back, channels(original)).allSatisfy { abs($0 - $1) <= 2 }, "\(channels(original)) → \(channels(converted)) → \(back)")
        }
    }

    /// An image is made in the palette's space.
    @Test func imagesSayTheirSpace() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let image = try #require(Screen.image([Screen.Palette(p3).green], width: 1, height: 1, space: p3))
        #expect(image.colorSpace.map { CFEqual($0, p3) } == true)
    }
}
