import Testing
@testable import Apple2Kit

/// The language card mapped into flat memory, a machine without ROMs, cards,
/// the I/O hook and copies: no ROM files needed (a ROM of $EA bytes stands in
/// where one is).
@Suite struct HostTests {
    private func plus() -> Apple2Machine {
        Apple2Machine(model: .apple2Plus, rom: [UInt8](repeating: 0xEA, count: 0x3000), diskROM: nil)
    }

    @Test func languageCardInFlatMemory() {
        let m = plus()
        #expect(m.cpu.read(0xD000) == 0xEA)                 // the ROM
        _ = m.cpu.read(0xC083); _ = m.cpu.read(0xC083)      // bank 2, read and write RAM
        #expect(!m.cpu.ioPages[0xD0] && !m.cpu.ioPages[0xFF])
        m.cpu.write(0xD000, 1)
        m.cpu.write(0xE000, 2)
        #expect(m.cpu.mem[0xD000] == 1 && m.cpu.mem[0xE000] == 2)
        _ = m.cpu.read(0xC08B); _ = m.cpu.read(0xC08B)      // bank 1
        #expect(m.languageCardBank == 1 && m.cpu.read(0xD000) == 0)
        m.cpu.write(0xD000, 3)
        _ = m.cpu.read(0xC083)                              // bank 2 again
        #expect(m.cpu.read(0xD000) == 1 && m.cpu.read(0xE000) == 2)
        _ = m.cpu.read(0xC080)                              // read RAM, write-protected: through `read`/`write`
        #expect(m.cpu.ioPages[0xD0])
        m.cpu.write(0xD000, 9)
        #expect(m.cpu.read(0xD000) == 1)
        _ = m.cpu.read(0xC082)                              // the ROM
        #expect(m.cpu.read(0xD000) == 0xEA && m.cpu.read(0xE000) == 0xEA)
        let ram = m.languageCardRAM
        #expect(ram[0] == 3 && ram[0x1000] == 1 && ram[0x2000] == 2)
        _ = m.cpu.read(0xC083); _ = m.cpu.read(0xC083)
        #expect(m.peek(0xD000) == 1 && m.languageCardRAM == ram)
    }

    @Test func withoutROMsTheCardIsRAM() {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        var card = [UInt8](repeating: 0, count: 0x4000)
        card[0] = 0x11; card[0x1000] = 0x22; card[0x3FFF] = 0x33
        var main = [UInt8](repeating: 0, count: 0x10000)
        main[0x0300] = 0x44
        m.load(memory: main, languageCard: card)
        #expect(m.cpu.mem[0x0300] == 0x44 && m.cpu.mem[0xD000] == 0x22 && m.cpu.mem[0xFFFF] == 0x33)
        _ = m.cpu.read(0xC082)                              // "read ROM": still RAM, bank 2
        #expect(m.readsLanguageCardRAM && m.cpu.read(0xD000) == 0x22)
        _ = m.cpu.read(0xC08A)                              // bank 1, written at once
        m.cpu.write(0xD001, 0x55)
        #expect(m.cpu.read(0xD000) == 0x11 && m.languageCardRAM[1] == 0x55)
        #expect(m.cpu.read(0xC600) == 0 && m.cpu.read(0xC300) == 0)     // no ROM in the slots
    }

    private final class Card: Apple2Card {
        let romPage = (0 ..< 256).map { UInt8($0 ^ 0x5A) }
        var accessed: [Int] = []
        func access(_ n: Int, write: Bool, value: UInt8, cycles: UInt64) -> UInt8 {
            accessed.append(n)
            return 0x77
        }
    }

    @Test func cardsAndTheHook() {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        let card = Card()
        m.insert(card, slot: 4)
        #expect(m.cpu.read(0xC40C) == 0x0C ^ 0x5A && m.cpu.mem[0xC4FB] == 0xFB ^ 0x5A)
        #expect(m.cpu.read(0xC0C3) == 0x77 && card.accessed == [3])
        m.insert(nil, slot: 4)
        #expect(m.cpu.read(0xC40C) == 0 && m.cpu.read(0xC0C3) == 0)

        var seen: [(UInt16, Bool)] = []
        m.ioHook = { address, write, _ in
            seen.append((address, write))
            return address == 0xC000 ? 0xC1 : nil
        }
        #expect(m.cpu.read(0xC000) == 0xC1)
        m.clicks = []
        _ = m.cpu.read(0xC030)                              // the machine's: a click
        #expect(m.takeClicks().count == 1 && seen.count == 2)
    }

    @Test func printOnABlankScreen() {
        let m = Apple2Machine(model: .apple2Plus, rom: nil, diskROM: nil)
        var rows = m.screenText().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(rows.count == 24 && rows.allSatisfy { $0 == String(repeating: " ", count: 40) })   // no ROM: blank
        m.print("Loading...")
        rows = m.screenText().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(rows[12] == String(repeating: " ", count: 15) + "LOADING..." + String(repeating: " ", count: 15))
        m.print("ABCD", atX: 38, y: 0, cls: false)                      // cut off at the row's end
        m.print("é" + String(repeating: "X", count: 50), y: 23, cls: false)     // too long, not ASCII
        m.print("off the screen", y: 24, cls: false)
        rows = m.screenText().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(rows[0].hasSuffix(" AB") && rows[1] == String(repeating: " ", count: 40))
        #expect(rows[23] == String(repeating: "X", count: 40) && rows[12].contains("LOADING"))
        #expect(m.cpu.mem.count == 0x10000)
        m.print("lower", atX: 0, y: 0, uppercased: false)
        #expect(m.cpu.mem[0x400] == 0xEC)                               // as given: "l"
        let e = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        e.print("Hi", atX: 0, y: 0)
        #expect(e.screenText().hasPrefix("Hi "))                        // the //e: lower case
    }

    @Test func copiesAreIndependent() {
        let m = plus()
        _ = m.cpu.read(0xC08B); _ = m.cpu.read(0xC08B)      // bank 1 in flat memory
        m.cpu.write(0xD000, 1)
        m.cpu.write(0x2000, 2)
        m.cpu.pc = 0x1234
        let c = m.copy()
        #expect(c.cpu.read(0xD000) == 1 && c.cpu.read(0x2000) == 2 && c.cpu.pc == 0x1234 && c.languageCardBank == 1)
        c.cpu.write(0xD000, 9)
        _ = c.cpu.read(0xC083)
        #expect(m.cpu.read(0xD000) == 1 && m.languageCardBank == 1 && c.languageCardBank == 2)
        #expect(c.languageCardRAM[0] == 9 && m.languageCardRAM[0] == 1)
    }
}
