import MOS6502

/// How a traced native (`Apple2Machine.addNative`) takes its routine's code.
public nonisolated struct NativeFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The code's cycles don't count: the clock goes back to the entry's
    /// cycle after the trace (the native adds what it wants,
    /// `NativeCall.cycles`).  What the code did by the clock in between (a
    /// click, a strobe) keeps the cycle it had.
    public static let ignoresCycles = NativeFlags(rawValue: 1 << 0)
    /// The code's writes don't reach the shadow (memory only): the native
    /// draws in its own way.  The natives the code calls run as code.
    public static let ignoresGraphics = NativeFlags(rawValue: 1 << 1)
}

/// What a traced native finds after its routine's code ran.
public nonisolated struct NativeCall: Sendable {
    /// The registers and stack pointer at the entry.
    public let entry: CPU6502.Registers
    public let entrySP: UInt8
    /// The cycles the code took.
    public let cycles: UInt64
}

public nonisolated extension Apple2Machine {
    /// Puts in a traced native at `address`, the entry of a routine called
    /// with JSR.  Where the CPU gets there (the native switched on, by its
    /// `name`; outside a native that ignores graphics):
    ///
    /// 1. `begin` looks at the machine at the entry: nil, the routine runs
    ///    as ever; else what to do after the code (it reads what it needs of
    ///    the parameters here, before the code changes them).
    /// 2. The routine's code runs, as the CPU would run it, up to its RTS
    ///    (the return address the stack has at the entry, with the stack
    ///    pointer 2 above the entry's).  Memory, registers and cycles are the
    ///    original's; its writes to the hi-res pages reach the shadow but
    ///    with `ignoresGraphics`; the clock goes back with `ignoresCycles`.
    /// 3. The native runs: what `begin` returned, with the cycles the code
    ///    took.  It may draw on the shadow (`writeShadow`), the host's own
    ///    layer, add cycles; memory is the code's, which it leaves as it is.
    /// 4. The registers, stack pointer and PC are put back as the code left
    ///    them.
    ///
    /// Code going astray (`maxSteps` instructions without returning, a
    /// BRK, a jam) leaves the native out: the CPU goes on from where it is.
    @discardableResult
    func addNative(at address: UInt16, name: String? = nil, flags: NativeFlags = [], maxSteps: Int = 5_000_000,
                   _ begin: @escaping (Apple2Machine) -> ((Apple2Machine, NativeCall) -> Void)?) -> HookID {
        addHook(at: address, name: name) { m in m.runNative(flags: flags, maxSteps: maxSteps, begin) }
    }

    internal func runNative(flags: NativeFlags, maxSteps: Int,
                            _ begin: (Apple2Machine) -> ((Apple2Machine, NativeCall) -> Void)?) -> Bool {
        guard hooks.ignoringGraphics == 0, let native = begin(self) else { return false }
        let entry = cpu.registers, sp = cpu.sp, start = cpu.cycles
        let back = (UInt16(cpu.read(0x100 | UInt16(sp &+ 1))) | UInt16(cpu.read(0x100 | UInt16(sp &+ 2))) << 8) &+ 1
        let ignoresGraphics = flags.contains(.ignoresGraphics)
        if ignoresGraphics {
            hooks.ignoringGraphics += 1
            shadowSuspended += 1
        }
        hooks.passThrough = cpu.pc
        var returned = false
        for _ in 0 ..< maxSteps {
            do { try step() } catch { break }
            if cpu.pc == back && cpu.sp == sp &+ 2 {
                returned = true
                break
            }
        }
        hooks.passThrough = nil
        if ignoresGraphics {
            hooks.ignoringGraphics -= 1
            shadowSuspended -= 1
        }
        // Astray: the instruction where it stopped runs (and fails again there).
        guard returned else { return false }
        let cycles = cpu.cycles - start
        if flags.contains(.ignoresCycles) { cpu.cycles = start }
        let (registers, leftSP, pc) = (cpu.registers, cpu.sp, cpu.pc)
        native(self, NativeCall(entry: entry, entrySP: sp, cycles: cycles))
        (cpu.registers, cpu.sp, cpu.pc) = (registers, leftSP, pc)
        return true
    }
}
