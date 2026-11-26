import MOS6502

/// A routine called (JSR) where a native is (`Apple2Machine.addNative`): the
/// native decides what the call does.  It may run the routine's own code
/// (`run`), drawing on a layer of its own or nowhere, do what it wants before and
/// after, or leave the code out.
public nonisolated final class NativeCall {
    /// The machine, its CPU at the routine's entry (the JSR done) until `run`.
    public unowned(unsafe) let machine: Apple2Machine
    /// The registers and stack pointer at the entry.
    public let entry: CPU6502.Registers
    public let entrySP: UInt8
    /// Where the routine returns to: its caller's next instruction (called by
    /// a JMP, `addNative(onJump:)`: the caller's caller's).
    public let returnAddress: UInt16
    /// The natives this call runs inside (0: called by the code itself).
    public let depth: Int
    /// The instructions `run` steps at most.
    let maxSteps: Int

    enum Outcome { case pending, returned, astray }
    var outcome = Outcome.pending

    init(_ machine: Apple2Machine, depth: Int, maxSteps: Int) {
        self.machine = machine
        let cpu = machine.cpu
        entry = cpu.registers
        entrySP = cpu.sp
        returnAddress = (UInt16(cpu.read(0x100 | UInt16(cpu.sp &+ 1)))
            | UInt16(cpu.read(0x100 | UInt16(cpu.sp &+ 2))) << 8) &+ 1
        self.depth = depth
        self.maxSteps = maxSteps
    }

    public var cpu: CPU6502 { machine.cpu }

    /// Runs the routine's code as the CPU runs it, up to its RTS: memory,
    /// registers and cycles the code's; the natives it calls run.  It draws
    /// where it draws now: on layer 0, or on the target of the native it
    /// runs inside.  The cycles the code took; nil: it went astray
    /// (`maxSteps` instructions without returning, a BRK, a jam), and the
    /// CPU goes on from where it is.  Once a call.
    @discardableResult
    public func run() -> UInt64? {
        run(drawing: nil)
    }

    /// `run()`, the code drawing on `target`: its writes of the hi-res pages
    /// ($2000-$5FFF) go to main memory, each byte then the layer's
    /// (`.layer(n)`, `run(into: 2)`); or, with `.discard`, nowhere, the code
    /// reading back what it wrote until it returns.  The natives it calls
    /// draw there too, unless they draw on a target of their own.
    @discardableResult
    public func run(into target: DrawTarget) -> UInt64? {
        run(drawing: target)
    }

    private func run(drawing target: DrawTarget?) -> UInt64? {
        precondition(outcome == .pending, "a native runs its code once")
        let m = machine, start = m.cpu.cycles, sp = entrySP &+ 2
        if let target { m.beginDrawing(on: target) }
        defer { if target != nil { m.endDrawing() } }
        for _ in 0 ..< maxSteps {
            do { try m.step() } catch { break }
            if m.cpu.pc == returnAddress && m.cpu.sp == sp {
                outcome = .returned
                return m.cpu.cycles - start
            }
        }
        outcome = .astray
        return nil
    }
}

public nonisolated extension Apple2Machine {
    /// Puts in a native for the routine at `address`: where the code calls it
    /// with JSR (not where a branch or a JMP gets there), `native` runs with
    /// the call, the JSR done.  With `onJump` also where a JMP gets there (a
    /// tail call: `returnAddress` is then the caller's caller's, where the
    /// routine's RTS goes; the routine's own JMPs to its start too, a call
    /// inside it), the JMP done.  It returns the cycles the call takes after
    /// the JSR (`run`'s: the original's; 0: none).  Without `run`, the code
    /// is left out: the call returns (RTS) with the registers as the native
    /// leaves them.  Code that goes astray in `run` leaves it where it is.
    /// One with a `name` can be switched off (`switchedOff`): the routine
    /// runs as ever.  At an address the first switched on runs.
    @discardableResult
    func addNative(at address: UInt16, name: String? = nil, maxSteps: Int = 5_000_000, onJump: Bool = false,
                   _ native: @escaping (NativeCall) -> UInt64) -> HookID {
        let id = hooks.add(address, name: name, kind: .native(maxSteps: maxSteps, onJump: onJump, native))
        refreshTrap(address)
        return id
    }

    /// The natives running (`NativeCall.depth`).
    var nativeDepth: Int { nativeCalls }

    /// The CPU's `onCall`: the native at `address`.
    internal func runNative(at address: UInt16) {
        guard let hook = hooks.natives[address], case .native(let maxSteps, _, let native) = hook.kind else { return }
        let start = cpu.cycles
        let call = NativeCall(self, depth: nativeCalls, maxSteps: maxSteps)
        nativeCalls += 1
        let cycles = native(call)
        nativeCalls -= 1
        switch call.outcome {
        case .pending:
            cpu.returnFromSubroutine()
            cpu.cycles = start + cycles
        case .returned:
            cpu.cycles = start + cycles
        case .astray:
            break
        }
    }
}
