import Foundation
import MOS6502
import Testing
@testable import Apple2Kit

/// A program's own kind of symbol.
private struct Sprite: Symbol {
    let address: Int
    let guess: Bool
}

/// A program in one build.
private final class Symbols: SharedSymbolMap {
    static let map = Symbols()

    let lives = Byte(0x4A)
    let shipX = Word(0x4B)
    let scores = Table(0x0300)
    /// LDA #3, STA LIVES, a variable of two bytes, RTS, NOP.
    let drawShip = Routine(0x6000, code: 0x6000 ..< 0x6004, 0x6006 ..< 0x6008, md5: "16d10fef759634feebd99350bff9b970")
    let drawShip2Flame = Routine(0x6100)
    let subDA44 = Routine(0xDA44, guess: true)
    let shape = Sprite(0x7000)
}

/// A program in two builds: what both have at the same place, and a class
/// each for what they have elsewhere.
private class ProgramSymbols: SymbolMap, @unchecked Sendable {
    let lives = Byte(0x4A)
    let scores = Table(0x0300)
}

private final class DiskSymbols: ProgramSymbols, @unchecked Sendable {
    let score = Byte(0x80)
    /// INC LIVES.
    let extraLife = Routine(0x6100, code: 0x6100 ..< 0x6102, md5: "f13dca79b58107c643633012ce010bea")
}

private final class TapeSymbols: ProgramSymbols, @unchecked Sendable {
    let score = Byte(0x84)
    let bonus = Byte(0x90)
    /// DEC LIVES there.
    let extraLife = Routine(0x6104, code: 0x6104 ..< 0x6106, md5: "cd6aa36a77ef629e4a7d7bd694c217e0")
}

private extension RAM where Map == Symbols {
    /// A sprite reads as its address.
    subscript(dynamicMember s: KeyPath<Symbols, Sprite>) -> Int { address(s) }
}

/// Code for what every build has: it runs on any build's map.
private func loseLife<Map: ProgramSymbols>(_ m: RAM<Map>) {
    m.lives &-= 1
    m.scores[0] = m.lives
}

/// The symbols of a program, its memory by their names and the debugger's
/// symbol file: no ROM files needed.
@Suite struct SymbolTests {
    /// The program's code in memory.
    private func memory() -> [UInt8] {
        var mem = [UInt8](repeating: 0, count: 0x10000)
        mem.replaceSubrange(0x6000 ..< 0x6008, with: [0xA9, 0x03, 0x85, 0x4A, 0x00, 0x00, 0x60, 0xEA])
        mem.replaceSubrange(0x6100 ..< 0x6102, with: [0xE6, 0x4B])
        return mem
    }

    @Test func addresses() {
        #expect(Symbols.address(\.lives) == 0x4A && Symbols.address(\.scores) == 0x0300 && Symbols.address(\.shape) == 0x7000)
        #expect(Symbols.map.address(\.shipX) == 0x4B && Symbols.map.drawShip.entry == 0x6000)
        // a build's own, and its parent's
        let disk = DiskSymbols(), tape = TapeSymbols()
        #expect(disk.address(\.score) == 0x80 && tape.address(\.score) == 0x84 && tape.address(\.bonus) == 0x90)
        #expect(disk.address(\.lives) == 0x4A && tape.address(\.lives) == 0x4A && tape.extraLife.entry == 0x6104)
    }

    @Test func names() {
        #expect(Symbols.named.map(\.name) == ["LIVES", "SHIP_X", "SCORES", "DRAW_SHIP", "DRAW_SHIP2_FLAME", "SUB_DA44_Q", "SHAPE"])
        #expect(Symbols.named[1].symbol is Word && Symbols.named[6].symbol is Sprite)
        for (property, name) in [("shipDX", "SHIP_DX"), ("lineAX", "LINE_AX"), ("xByteTable", "X_BYTE_TABLE"),
                                 ("keyTHandler", "KEY_T_HANDLER"), ("ships4Update", "SHIPS4_UPDATE"),
                                 ("subDA44", "SUB_DA44"), ("flag9C51", "FLAG_9C51"), ("random", "RANDOM")] {
            #expect(symbolName(property) == name)
        }
        #expect(symbolName("stepDX", guess: true) == "STEP_DX_Q")
        #expect(Symbols.name(of: \.drawShip) == "DRAW_SHIP" && Symbols.name(of: \.subDA44) == "SUB_DA44_Q")
        #expect(Symbols.name(Routine.self, at: 0x6100) == "DRAW_SHIP2_FLAME")
        #expect(Symbols.name(Routine.self, at: 0x6104) == nil && Symbols.name(Byte.self, at: 0x6000) == nil)
        // a build's map: its parent's symbols first
        let tape = TapeSymbols()
        #expect(tape.named.map(\.name) == ["LIVES", "SCORES", "SCORE", "BONUS", "EXTRA_LIFE"])
        #expect(tape.name(of: \.extraLife) == "EXTRA_LIFE" && tape.name(Byte.self, at: 0x84) == "SCORE")
        #expect(DiskSymbols().name(Byte.self, at: 0x84) == nil && (tape as ProgramSymbols).name(Byte.self, at: 0x90) == "BONUS")
    }

    @Test func fingerprints() {
        let map = Symbols.map
        var mem = memory()
        #expect(map.drawShip.matches(mem) == true)
        #expect(map.drawShip.code?.digest(mem) == "16d10fef759634feebd99350bff9b970")
        mem[0x6004] = 0x55                                  // a variable between the instructions
        #expect(map.drawShip.matches(mem) == true)
        mem[0x6001] = 0x04                                  // LDA #4
        #expect(map.drawShip.matches(mem) == false)
        #expect(map.subDA44.matches(mem) == nil && map.subDA44.code == nil)             // no fingerprint
        // each build's own code
        #expect(DiskSymbols().extraLife.matches(memory()) == true && TapeSymbols().extraLife.matches(memory()) == false)
        var tape = memory()
        tape.replaceSubrange(0x6104 ..< 0x6106, with: [0xC6, 0x4B])
        #expect(TapeSymbols().extraLife.matches(tape) == true && TapeSymbols().extraLife.code?.ranges == [0x6104 ..< 0x6106])
    }

    @Test func memoryByName() {
        let cpu = CPU6502(memory: memory())
        let ship = cpu.withRAM(Symbols.map) { m -> Int in
            m.lives = 3
            m.lives &-= 1
            m.shipX = 0x1234
            m.scores[2] = m.lives &+ 0x40
            m.scores[UInt8(3)] = 0x99
            m[\.lives] &+= 0x10
            #expect(m.scores.word(2) == 0x9942 && m.address(\.shipX) == 0x4B && m.shape == 0x7000)
            m.setWord(0xFFFF, 0xBEEF)                       // wraps at 64K
            #expect(m[0x10000] == 0xBE && m.word(0xFFFF) == 0xBEEF && m[0x1004A] == 0x12)
            return m.shipX
        }
        #expect(ship == 0x1234 && cpu.mem[0x4A] == 0x12 && cpu.mem[0x4B] == 0x34 && cpu.mem[0x4C] == 0x12)
        #expect(cpu.mem[0x302] == 0x42 && cpu.mem[0x303] == 0x99 && cpu.mem[0xFFFF] == 0xEF && cpu.mem[0] == 0xBE)
        // a build's map: its own symbols and its parent's; code for the parent's runs on either
        let disk = DiskSymbols(), tape = TapeSymbols()
        cpu.withRAM(tape) { m in
            m.score = 9
            m.bonus = 5
            m.lives = 7
            loseLife(m)
        }
        #expect(cpu.mem[0x84] == 9 && cpu.mem[0x90] == 5 && cpu.mem[0x4A] == 6 && cpu.mem[0x300] == 6)
        cpu.withRAM(disk) { m in
            m.score = 1
            loseLife(m)
        }
        #expect(cpu.mem[0x80] == 1 && cpu.mem[0x84] == 9 && cpu.mem[0x4A] == 5)
        // a memory image
        var image = memory()
        image.withUnsafeMutableBufferPointer { RAM($0.baseAddress!, map: Symbols.map).lives = 0xAA }
        #expect(image[0x4A] == 0xAA)
    }

    @Test func watchedPagesHearOfTheWrites() {
        let cpu = CPU6502(memory: memory())
        var heard: [[Int]] = []
        cpu.onWrite = { heard.append([Int($0), Int($1), Int($2)]) }
        for page in 0x20 ..< 0x40 { cpu.watchedPages[page] = true }
        cpu.mem[0x2005] = 0x11
        cpu.withRAM(Symbols.map) { m in
            m[0x2005] = 0x22                                // a watched page: the byte as it was, and as written
            m.setWord(0x3FFF, 0x0807)                       // its second byte is past the pages
            m[0x1FFF] = 1
            m.lives = 4
            m.scores[0] = 5
            #expect(m[0x2005] == 0x22)
        }
        #expect(heard == [[0x2005, 0x11, 0x22], [0x3FFF, 0, 0x07]])
        #expect(cpu.mem[0x2005] == 0x22 && cpu.mem[0x4000] == 0x08 && cpu.mem[0x1FFF] == 1 && cpu.mem[0x4A] == 4)
        // as the 6502's own write
        cpu.write(0x2006, 0x33)
        #expect(heard.last == [0x2006, 0, 0x33])
    }

    @Test func symbolFile() {
        let file = SymbolFile(Symbols.map, comments: ["A program"])
        #expect(file.symbols.count == 7)
        #expect(file.text == ["; A program", "",
                              "6000 DRAW_SHIP", "6100 DRAW_SHIP2_FLAME", "  4A LIVES", "0300 SCORES",
                              "7000 SHAPE", "  4B SHIP_X", "DA44 SUB_DA44_Q", ""].joined(separator: "\r\n"))
        // a build's, and another map's names after a prefix
        var tape = SymbolFile()
        tape.add(TapeSymbols().named.filter { $0.symbol is Byte })
        tape.add(Symbols.named.filter { $0.symbol is Word }, prefix: "P_")
        #expect(tape.text == "  90 BONUS\r\n  4A LIVES\r\n  4B P_SHIP_X\r\n  84 SCORE\r\n")
    }
}
