import MOS6502
import Testing
@testable import Apple2Kit

/// The writes to main memory's hi-res pages (`onPageWrite`), on a machine
/// without ROMs.
@Suite struct PageWriteTests {
    @Test func toldWhileSet() throws {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        // $0300: LDA #$AA / STA $2000 / STA $1000 / STA $4001 / RTS
        m.cpu.mem.replaceSubrange(0x0300 ..< 0x030C, with: [0xA9, 0xAA, 0x8D, 0x00, 0x20, 0x8D, 0x00, 0x10, 0x8D, 0x01, 0x40, 0x60])
        var seen: [Int] = []
        m.onPageWrite = { seen.append($0) }
        #expect(m.cpu.watchedPages[0x20] && m.cpu.watchedPages[0x5F] && !m.cpu.watchedPages[0x10])
        m.cpu.sp = 0xFF
        try m.cpu.call(0x0300)
        #expect(seen == [0x2000, 0x4001] && m.cpu.mem[0x2000] == 0xAA && m.cpu.mem[0x4001] == 0xAA)
        #expect(m.copy().onPageWrite == nil)
        m.onPageWrite = nil
        #expect(!m.cpu.watchedPages[0x20])
    }
}
