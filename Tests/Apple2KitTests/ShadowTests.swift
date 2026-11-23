import MOS6502
import Testing
@testable import Apple2Kit

/// The shadow of the hi-res pages and the traced natives, on a machine
/// without ROMs.
@Suite struct ShadowTests {
    /// $0300: `LDA #$AA / STA $2000 / JSR $0310 / LDX #$07 / RTS`;
    /// $0310: `LDA #$55 / STA $4001 / INC $10 / LDY #$03 / RTS` (the
    /// routine the natives trace).
    private func machine() -> Apple2Machine {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        m.cpu.mem.replaceSubrange(0x0300 ..< 0x030B, with: [0xA9, 0xAA, 0x8D, 0x00, 0x20, 0x20, 0x10, 0x03, 0xA2, 0x07, 0x60])
        m.cpu.mem.replaceSubrange(0x0310 ..< 0x031A, with: [0xA9, 0x55, 0x8D, 0x01, 0x40, 0xE6, 0x10, 0xA0, 0x03, 0x60])
        m.keepsShadow = true
        return m
    }

    private func run(_ m: Apple2Machine) throws {
        m.cpu.sp = 0xFF
        try m.cpu.call(0x0300)
    }

    @Test func followsWrites() throws {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        m.cpu.mem[0x2100] = 0x11
        m.keepsShadow = true                    // starts as a copy
        #expect(m.shadow[0x0100] == 0x11)
        m.cpu.mem.replaceSubrange(0x0300 ..< 0x030B, with: [0xA9, 0xAA, 0x8D, 0x00, 0x20, 0x20, 0x10, 0x03, 0xA2, 0x07, 0x60])
        m.cpu.mem.replaceSubrange(0x0310 ..< 0x031A, with: [0xA9, 0x55, 0x8D, 0x01, 0x40, 0xE6, 0x10, 0xA0, 0x03, 0x60])
        var seen: [Int] = []
        m.onShadowWrite = { seen.append($0) }
        try run(m)
        #expect(m.shadow[0x0000] == 0xAA && m.shadow[0x2001] == 0x55)
        #expect(seen == [0x2000, 0x4001])
        #expect(m.shadowScreen(page2: true).bytes[1] == 0x55)
        m.writeShadow(0x2000, 0x01)              // the shadow alone
        #expect(m.shadow[0] == 0x01 && m.cpu.mem[0x2000] == 0xAA)
        let c = m.copy()
        #expect(c.keepsShadow && c.shadow == m.shadow)
    }

    @Test func tracedNative() throws {
        let m = machine()
        var call: NativeCall?
        var a: UInt8 = 0
        m.addNative(at: 0x0310, name: "R", flags: .ignoresGraphics) { m in
            a = m.cpu.a                          // at the entry
            return { m, c in
                call = c
                m.cpu.a = 0                      // put back after it
                m.writeShadow(0x4001, 0x77)
            }
        }
        try run(m)
        // Memory, registers and cycles as the code's, the shadow without its write.
        #expect(m.cpu.mem[0x4001] == 0x55 && m.cpu.mem[0x10] == 1 && m.cpu.a == 0x55 && m.cpu.y == 3 && m.cpu.x == 7)
        #expect(m.shadow[0x0000] == 0xAA && m.shadow[0x2001] == 0x77)
        #expect(a == 0xAA && call?.entry.a == 0xAA && call?.entrySP == 0xFB)
        // LDA #, STA abs, INC zp, LDY #, RTS: 2 + 4 + 5 + 2 + 6
        #expect(call?.cycles == 19)
        let plain = machine()
        try run(plain)
        #expect(m.cpu.cycles == plain.cpu.cycles && plain.shadow[0x2001] == 0x55)
    }

    @Test func ignoresCyclesAndDeclines() throws {
        let m = machine()
        m.addNative(at: 0x0310, flags: .ignoresCycles) { _ in { m, c in m.cpu.cycles += 1 } }
        let plain = machine()
        try run(plain)
        try run(m)
        #expect(m.cpu.cycles == plain.cpu.cycles - 19 + 1 && m.shadow[0x2001] == 0x55)
        // Declined at the entry: the code runs as ever.
        let d = machine()
        var finished = false
        d.addNative(at: 0x0310, flags: .ignoresGraphics) { _ in nil }
        d.addNative(at: 0x0300) { _ in { _, _ in finished = true } }
        try run(d)
        #expect(d.shadow[0x2001] == 0x55 && d.cpu.mem[0x10] == 1)
        // the outer native: traced to the sentinel's RTS
        #expect(finished)
    }

    @Test func nativesInside() throws {
        // Inside a native that ignores graphics the natives run as code.
        let m = machine()
        var inner = 0
        m.addNative(at: 0x0300, flags: .ignoresGraphics) { _ in { _, _ in } }
        m.addNative(at: 0x0310) { _ in inner += 1; return { _, _ in } }
        try run(m)
        #expect(inner == 0 && m.shadow[0] == 0 && m.shadow[0x2001] == 0 && m.cpu.x == 7)
        // Inside one that doesn't, they run.
        let n = machine()
        var order: [String] = []
        n.addNative(at: 0x0300) { _ in { _, _ in order.append("outer") } }
        n.addNative(at: 0x0310, flags: .ignoresGraphics) { _ in { _, _ in order.append("inner") } }
        try run(n)
        #expect(order == ["inner", "outer"] && n.shadow[0] == 0xAA && n.shadow[0x2001] == 0)
    }

    @Test func switchedOff() throws {
        let m = machine()
        var ran = false
        m.addNative(at: 0x0310, name: "R", flags: .ignoresGraphics) { _ in { _, _ in ran = true } }
        m.switchedOff = ["R"]
        try run(m)
        #expect(!ran && m.shadow[0x2001] == 0x55)
    }

    @Test func astray() throws {
        // A routine that never returns: the native is left out, the CPU goes on.
        let m = machine()
        m.cpu.mem.replaceSubrange(0x0310 ..< 0x0313, with: [0x4C, 0x10, 0x03])     // JMP $0310
        var ran = false
        m.addNative(at: 0x0310, flags: .ignoresGraphics, maxSteps: 100) { _ in { _, _ in ran = true } }
        m.cpu.sp = 0xFF
        #expect(throws: CPU6502.CPUError.self) { try m.cpu.call(0x0300, maxSteps: 1000) }
        #expect(!ran && m.hooks.ignoringGraphics == 0 && m.shadowSuspended == 0)
    }
}
