import MOS6502
import Testing
@testable import Apple2Kit

/// The //e's aux memory (the extended 80-column card), 80 columns and double
/// hi-res, on a //e without ROMs.
@Suite struct IIeTests {
    private func iie(_ model: Apple2Machine.Model = .apple2e) -> Apple2Machine {
        Apple2Machine(model: model, rom: nil, diskROM: nil)
    }

    /// Throws switch `address` (a write, as the //e's $C000-$C00F want).
    private func set(_ m: Apple2Machine, _ address: UInt16) {
        m.cpu.write(address, 0)
    }

    @Test func enhancedHasA65C02() {
        #expect(iie(.apple2eEnhanced).cpu.variant == .cmos65C02)
        #expect(iie().cpu.variant == .nmos6502)
    }

    @Test func ramReadAndRamWrite() {
        let m = iie()
        m.cpu.write(0x1234, 0x11)
        set(m, 0xC005)                                      // RAMWRT: writes to aux
        #expect(m.cpu.ioWritePages[0x12] && m.cpu.read(0xC014) & 0x80 != 0)
        m.cpu.write(0x1234, 0x22)
        #expect(m.cpu.read(0x1234) == 0x11 && m.cpu.mem[0x1234] == 0x11)
        set(m, 0xC003)                                      // RAMRD: reads aux, in `cpu.mem`
        #expect(!m.cpu.ioWritePages[0x12] && m.cpu.mem[0x1234] == 0x22)
        set(m, 0xC004)                                      // writes to main again
        m.cpu.write(0x1234, 0x33)
        #expect(m.cpu.read(0x1234) == 0x22)
        set(m, 0xC002)
        #expect(m.cpu.read(0x1234) == 0x33)
        #expect(m.ram()[0x1234] == 0x33 && m.ram(aux: true)[0x1234] == 0x22)
        #expect(m.cpu.read(0x0080) == 0)                    // the zero page: ALTZP's, not RAMRD's
    }

    @Test func store80AndPage2PickTheBankOfPage1() {
        let m = iie()
        set(m, 0xC001)                                      // 80STORE
        _ = m.cpu.read(0xC055)                              // PAGE2: aux text page 1
        m.cpu.write(0x0400, 0xC1)
        m.cpu.write(0x2000, 0x7F)                           // HIRES off: hi-res page 1 by RAMWRT, main
        #expect(m.video.page2 && !m.displayMode.page2)
        _ = m.cpu.read(0xC057)                              // HIRES: aux hi-res page 1 too
        m.cpu.write(0x2001, 0x55)
        _ = m.cpu.read(0xC054)
        #expect(m.cpu.read(0x0400) == 0xA0 && m.cpu.read(0x2000) == 0x7F && m.cpu.read(0x2001) == 0)   // main: blank
        #expect(m.ram(aux: true)[0x0400] == 0xC1 && m.ram(aux: true)[0x2001] == 0x55)
        set(m, 0xC000)
        _ = m.cpu.read(0xC055)                              // without 80STORE: page 2 shown
        #expect(m.displayMode.page2 && m.cpu.read(0x0400) == 0xA0)
    }

    @Test func altZPSwapsTheStackAndTheLanguageCard() {
        let m = iie()
        m.cpu.write(0x01FF, 0x42)
        m.cpu.write(0xD000, 0x05)                           // no ROM: the card is RAM
        set(m, 0xC009)                                      // ALTZP
        #expect(m.cpu.mem[0x1FF] == 0 && m.cpu.read(0xD000) == 0)
        m.cpu.write(0xD000, 0x06)
        m.cpu.write(0x00FF, 0x07)
        set(m, 0xC008)
        #expect(m.cpu.mem[0x1FF] == 0x42 && m.cpu.read(0xD000) == 0x05 && m.cpu.read(0x00FF) == 0)
        #expect(m.languageCardRAM[0x1000] == 0x05)
        set(m, 0xC009)
        #expect(m.languageCardRAM[0x1000] == 0x05 && m.cpu.read(0xD000) == 0x06 && m.cpu.read(0x00FF) == 0x07)
    }

    @Test func copiesAndResetKeepAuxMemory() {
        let m = iie()
        set(m, 0xC005)
        m.cpu.write(0x6000, 0x99)
        let c = m.copy()
        c.cpu.write(0x6000, 0x98)
        #expect(m.ram(aux: true)[0x6000] == 0x99 && c.ram(aux: true)[0x6000] == 0x98)
        set(m, 0xC003)
        m.reset()                                           // main memory again, aux kept
        #expect(m.cpu.read(0x6000) == 0 && !m.cpu.ioWritePages[0x60] && m.ram(aux: true)[0x6000] == 0x99)
    }

    @Test func eightyColumns() {
        let m = iie()
        m.print("BDF", atX: 0, y: 0)                        // main: the odd columns
        set(m, 0xC005)
        for (i, c) in "ACE".utf8.enumerated() { m.cpu.write(0x0400 + UInt16(i), c | 0x80) }
        set(m, 0xC004)
        set(m, 0xC00D)                                      // 80COL
        #expect(m.screenText().hasPrefix("ABCDEF@ @ "))   // aux memory's zeros: inverse @
        #expect(m.video.description == "80-column text")
    }

    @Test func doubleHiresColours() {
        let m = iie()
        for s: UInt16 in [0xC050, 0xC052, 0xC057, 0xC05E] { _ = m.cpu.read(s) }
        set(m, 0xC00D)
        #expect(m.displayMode.description == "Double hi-res")
        // magenta (lo-res 1) on line 0, dark blue (lo-res 2) on line 1: aux, main, aux, main
        let lines: [(address: UInt16, bytes: [UInt8])] = [(0x2000, [0x08, 0x11, 0x22, 0x44]), (0x2400, [0x11, 0x22, 0x44, 0x08])]
        for (address, bytes) in lines {
            for (i, byte) in bytes.enumerated() {
                set(m, i & 1 == 0 ? 0xC005 : 0xC004)
                m.cpu.write(address + UInt16(i / 2), byte)
            }
        }
        set(m, 0xC004)
        let pixels = m.screenPixels(style: .color)
        #expect(pixels[0 ..< 28].allSatisfy { $0 == Screen.loresColours[1] })
        #expect(pixels[560 ..< 588].allSatisfy { $0 == Screen.loresColours[2] })
        #expect(pixels[28] == Screen.black)
        let mono = m.screenPixels(style: .monochrome)
        #expect(mono[3] == Screen.green && mono[0 ..< 3].allSatisfy { $0 == Screen.black })
        _ = m.cpu.read(0xC05F)                              // DHIRES off: hi-res from main memory alone
        #expect(m.displayMode.description == "Hi-res")
    }
}
