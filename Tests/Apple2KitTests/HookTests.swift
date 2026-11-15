import MOS6502
import Testing
@testable import Apple2Kit

/// Hooks on a machine without ROMs: Swift where the CPU reaches an address,
/// observers, switches, copies, the host.
@Suite struct HookTests {
    /// A host keeping its own state with the machine.
    private final class Host {
        var seen: [String] = []
    }

    /// A machine running `INC $10 / INC $11 / RTS` from $0300, called like JSR.
    private func machine() -> Apple2Machine {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        m.cpu.mem.replaceSubrange(0x0300 ..< 0x0305, with: [0xE6, 0x10, 0xE6, 0x11, 0x60])
        return m
    }

    private func run(_ m: Apple2Machine) throws {
        m.cpu.sp = 0xFF
        try m.cpu.call(0x0300)
    }

    @Test func hookInPlaceOfCode() throws {
        let m = machine()
        let id = m.addHook(at: 0x0300) { m in
            m.cpu.mem[0x10] &+= 10                  // in place of the routine
            m.cpu.returnFromSubroutine()
            return true
        }
        #expect(m.cpu.traps[0x0300] && m.isHooked(0x0300))
        try run(m)
        #expect(m.cpu.mem[0x10] == 10 && m.cpu.mem[0x11] == 0)
        m.removeHook(id)
        #expect(!m.cpu.traps[0x0300] && !m.isHooked(0x0300))
        try run(m)
        #expect(m.cpu.mem[0x10] == 11 && m.cpu.mem[0x11] == 1)
    }

    @Test func observersAndOrder() throws {
        let m = machine()
        var seen: [String] = []
        m.addHook(at: 0x0302) { _ in seen.append("declines"); return false }
        m.addObserver(at: 0x0302) { _ in seen.append("looks") }
        m.addObserver(at: 0x0302, first: true) { _ in seen.append("looks first") }
        m.addHook(at: 0x0302) { _ in seen.append("handles"); return false }
        try run(m)
        #expect(seen == ["looks first", "looks", "declines", "handles"])
        #expect(m.cpu.mem[0x10] == 1 && m.cpu.mem[0x11] == 1)        // the instructions ran
        // an observer taking out a hook after it at the same address
        let m2 = machine()
        var later: HookID?
        var ran = false
        m2.addObserver(at: 0x0300) { m in if let later { m.removeHook(later) } }
        later = m2.addHook(at: 0x0300) { _ in ran = true; return false }
        try run(m2)
        #expect(!ran && !m2.isHooked(0x0301))
    }

    @Test func switches() throws {
        let m = machine()
        var calls = 0
        m.addHook(at: 0x0300, name: "FAST_INC") { m in
            calls += 1
            m.cpu.mem[0x10] &+= 1
            m.cpu.mem[0x11] &+= 1
            m.cpu.returnFromSubroutine()
            return true
        }
        m.addObserver(at: 0x0302) { _ in calls += 100 }
        try run(m)
        #expect(calls == 1 && m.cpu.mem[0x10] == 1)
        m.switchedOff = ["FAST_INC"]                // the code runs, the CPU doesn't stop there
        #expect(!m.cpu.traps[0x0300] && !m.isHooked(0x0300) && m.cpu.traps[0x0302])
        try run(m)
        #expect(calls == 101 && m.cpu.mem[0x10] == 2 && m.cpu.mem[0x11] == 2)
        m.switchedOff = []
        #expect(m.cpu.traps[0x0300])
        try run(m)
        #expect(calls == 102)
    }

    @Test func copiesAndTheHost() throws {
        let m = machine()
        let host = Host()
        m.host = host
        m.addHook(at: 0x0300, name: "COUNT") { m in
            (m.host as? Host)?.seen.append("hook")
            return false
        }
        m.switchedOff = ["OTHER"]
        let c = m.copy()
        #expect(c.host == nil && c.switchedOff == ["OTHER"] && c.cpu.traps[0x0300])
        let other = Host()
        c.host = other
        try run(c)
        #expect(other.seen == ["hook"] && host.seen.isEmpty)
        c.switchedOff = ["COUNT"]                   // the copy's switches are its own
        #expect(!c.cpu.traps[0x0300] && m.cpu.traps[0x0300])
    }

    @Test func theMouseCardsTrapsStay() {
        let m = machine()
        m.mouseEnabled = true
        let entry = MouseCard.Call.readMouse.entry
        #expect(m.cpu.traps[Int(entry)])
        let id = m.addObserver(at: entry) { _ in }
        m.removeHook(id)
        #expect(m.cpu.traps[Int(entry)])            // still the firmware's
        m.mouseEnabled = false
        #expect(!m.cpu.traps[Int(entry)])
    }
}
