import Testing
@testable import Apple2Kit

/// The keyboard (its repeat, any-key-down), the game port's timers and the
/// mouse card, with its interrupt: on machines without ROMs.
@Suite struct InputTests {
    @Test func theIIeRepeatsAKeyHeld() {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        m.cpu.cycles = 0
        m.keyDown(0x41, id: 1)
        #expect(m.cpu.read(0xC000) == 0xC1)
        #expect(m.cpu.read(0xC010) == 0xC1)                 // any key down, the key
        #expect(m.cpu.read(0xC000) == 0x41)
        m.cpu.cycles = Keyboard.repeatDelay - 1
        #expect(m.cpu.read(0xC000) == 0x41)
        m.cpu.cycles = Keyboard.repeatDelay
        #expect(m.cpu.read(0xC000) == 0xC1)                 // repeated
        _ = m.cpu.read(0xC010)
        m.cpu.cycles += Keyboard.repeatPeriod - 1
        #expect(m.cpu.read(0xC000) == 0x41)
        m.cpu.cycles += 1
        #expect(m.cpu.read(0xC000) == 0xC1)
        m.keyUp(id: 1)
        #expect(m.cpu.read(0xC010) == 0x41)                 // no key down
        m.cpu.cycles += 10 * Keyboard.repeatPeriod
        #expect(m.cpu.read(0xC000) == 0x41)
    }

    @Test func thePlusDoesNotRepeat() {
        let m = Apple2Machine(model: .apple2Plus, rom: nil, diskROM: nil)
        m.keyDown(0x41, id: 1)
        _ = m.cpu.read(0xC010)
        m.cpu.cycles += 10 * Keyboard.repeatPeriod + Keyboard.repeatDelay
        #expect(m.cpu.read(0xC000) == 0x41)
    }

    @Test func paddleTimers() {
        let m = Apple2Machine(model: .apple2Plus, rom: nil, diskROM: nil)
        m.cpu.cycles = 100
        _ = m.cpu.read(0xC070)
        #expect(m.cpu.read(0xC064) == 0x80)                 // nothing plugged in: never runs out
        m.cpu.cycles = 1_000_000
        #expect(m.cpu.read(0xC064) == 0x80 && m.cpu.read(0xC067) == 0x80)

        m.gamePort.joystick = GamePort.Joystick(x: 0, y: 255, buttons: [true, false])
        m.cpu.cycles = 2_000_000
        _ = m.cpu.read(0xC070)
        #expect(m.cpu.read(0xC064) == 0x80)                 // 0: out after the strobe's cycle
        m.cpu.cycles += 1
        #expect(m.cpu.read(0xC064) == 0)
        let end = 2_000_000 + UInt64(287 * GamePort.cyclesPerStep)     // 255 as 287
        m.cpu.cycles = end
        #expect(m.cpu.read(0xC065) == 0x80)
        m.cpu.cycles = end + 1
        #expect(m.cpu.read(0xC065) == 0)
        #expect(m.cpu.read(0xC061) == 0x80 && m.cpu.read(0xC062) == 0)

        m.gamePort.joystick?.y = 100
        m.cpu.cycles = 3_000_000
        _ = m.cpu.read(0xC070)
        m.gamePort.joystick?.y = 0
        m.cpu.cycles += 2                                   // still running: the strobe doesn't restart it
        _ = m.cpu.read(0xC070)
        let y100 = 3_000_000 + UInt64(100 * GamePort.cyclesPerStep)
        m.cpu.cycles = y100
        #expect(m.cpu.read(0xC065) == 0x80)
        m.cpu.cycles = y100 + 1
        #expect(m.cpu.read(0xC065) == 0)
    }

    /// SETMOUSE (on, VBL interrupts), CLI, and a handler that serves the
    /// interrupt and counts it: one each frame.
    @Test func theMouseCardInterruptsAtEachVerticalBlank() throws {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        #expect(m.cpu.read(0xC40C) == 0)                    // not there yet
        m.mouseEnabled = true
        #expect(m.cpu.read(0xC40C) == 0x20 && m.cpu.read(0xC4FB) == 0xD6)
        #expect(m.cpu.read(0xC412) == 0x80 && m.cpu.read(0xC413) == 0x81)
        let program: [UInt8] = [0xA9, 0x09, 0x20, 0x80, 0xC4, 0x58, 0x4C, 0x06, 0x02]   // LDA #9 JSR SETMOUSE CLI JMP *
        let handler: [UInt8] = [0x20, 0x81, 0xC4, 0xE6, 0x10, 0x40]                     // JSR SERVEMOUSE INC $10 RTI
        m.cpu.mem.replaceSubrange(0x200 ..< 0x200 + program.count, with: program)
        m.cpu.mem.replaceSubrange(0x300 ..< 0x300 + handler.count, with: handler)
        (m.cpu.mem[0xFFFE], m.cpu.mem[0xFFFF]) = (0x00, 0x03)
        (m.cpu.pc, m.cpu.cycles, m.cpu.sp) = (0x200, 0, 0xFF)
        try m.run(cycles: 2 * Apple2Machine.cyclesPerFrame)
        #expect(m.cpu.mem[0x10] == 2)
        #expect(m.cpu.mem[MouseCard.Hole.status] & MouseCard.Bit.vblInterrupt != 0)
        #expect(m.cpu.mem[MouseCard.Hole.mode] == 9)
    }

    @Test func readMouse() throws {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        m.mouseEnabled = true
        func call(_ c: MouseCard.Call, a: UInt8 = 0) throws {
            m.cpu.a = a
            try m.cpu.call(c.entry)
        }
        try call(.setMouse, a: 1)
        m.moveMouse(dx: 5, dy: -3)                          // clamped at 0
        m.mouseButton(down: true)
        try call(.readMouse)
        #expect(m.cpu.mem[MouseCard.Hole.status] == 0xA0 && m.cpu.mem[MouseCard.Hole.xLow] == 5 && m.cpu.mem[MouseCard.Hole.yLow] == 0)
        try call(.readMouse)
        #expect(m.cpu.mem[MouseCard.Hole.status] == 0xC0)   // down, and at the last read
        m.mouseButton(down: false)
        try call(.readMouse)
        #expect(m.cpu.mem[MouseCard.Hole.status] == 0x40)
        m.mouseReportsClickOnce = true
        m.mouseButton(down: true)
        try call(.readMouse)
        try call(.readMouse)
        #expect(m.cpu.mem[MouseCard.Hole.status] == 0)      // the one press read already
        try call(.serveMouse)
        #expect(m.cpu.p & 1 == 1)                           // no interrupt of the mouse's
    }
}
