import MOS6502

/// Which bits of the code's registers are still a page byte's, unchanged and
/// in place, followed while the code draws on the layers
/// (`Apple2Machine.trackFlow`): the dots a drawing passes through.
///
/// A drawing routine merges what it draws into the byte on the page:
/// `(old AND keep) OR set`, a sprite's mask for `keep`.  The dots it keeps
/// are what lies under it, not its own drawing; but a dot that is the same
/// before and after is either one it kept or one it cleared and set again
/// (or cleared again), and the two bytes don't tell which.  The code does:
/// every bit it stores is either a bit it read from the byte and passed
/// through as it was (an AND with a 1, an ORA or EOR with a 0) or one it
/// computed.  So the machine follows the bits, instruction by instruction,
/// for A, X and Y: those still a page byte's, and which byte's.
///
/// * A load from a page byte starts them: all its bits; any other load,
///   none.
/// * `AND` keeps a bit of A where the operand has a 1, and one of the
///   operand's (a page byte's) where A has a 1; `ORA` and `EOR` where the
///   other has a 0.  A byte with itself: `AND` and `ORA` keep its bits, `EOR`
///   makes them the code's (x EOR x is 0).  The transfers copy them.  Anything else that changes a
///   register (a shift, an increment, arithmetic, a pull) makes its bits the
///   code's.
/// * A store into the byte they came from leaves them as the dots its layer
///   passed through (`Apple2Machine.passedDots(at:)`): the layers under it
///   show there, and its hidden dots stay hidden (`pageWritten`).
///
/// What isn't followed counts as the code's own drawing: a bit that goes
/// through memory (the stack, a zero-page temporary), moves (a shift) or
/// into another byte, and an instruction a hook may take.  The code runs as
/// ever: this only reads the machine, its memory, registers and cycles are
/// the original's.
nonisolated struct BitFlow {
    /// The bits still unchanged and in place from one hi-res byte.
    struct Source {
        /// Meaningful only when the mask is nonzero.
        var address: UInt16 = 0
        var mask: UInt8 = 0
    }

    var a = Source(), x = Source(), y = Source()
    /// The source of the bits the current instruction stores.
    var store = Source()

    /// The dots the running instruction stores into the byte at `address`
    /// as they were in it.
    func passed(at address: Int) -> UInt8 { Int(store.address) == address ? store.mask & 0x7F : 0 }
}

nonisolated extension Apple2Machine {
    /// A byte of the hi-res pages, which have layers (not the //e's aux memory).
    @inline(__always)
    func isPageByte(_ address: Int) -> Bool {
        address >= Apple2Machine.hiresBase && address < Apple2Machine.hiresBase + Apple2Machine.hiresSize
            && !(isIIe && isAuxInMemory(address >> 8))
    }

    /// The instruction at PC is about to run (`step`, `call`): follows its
    /// bits (`BitFlow`), and what it stores for `pageWritten`.  Reads the
    /// machine only, the registers and memory as they are before it.
    func trackFlow() {
        flow.store = .init()
        let pc = Int(cpu.pc)
        // A hook may take the instruction in place of the CPU; code in an I/O page isn't plain memory.
        guard !cpu.traps[pc], !cpu.ioPages[pc >> 8] else {
            flow = BitFlow()
            return
        }
        let opcode = opcodes[Int(cpu.mem[pc])]
        let mode = opcode.mode
        switch opcode.mnemonic {
        case .lda: flow.a = loadSource(mode, at: pc)
        case .ldx: flow.x = loadSource(mode, at: pc)
        case .ldy: flow.y = loadSource(mode, at: pc)
        case .lax:
            flow.a = loadSource(mode, at: pc)
            flow.x = flow.a
        case .sta: flow.store = flow.a
        case .stx: flow.store = flow.x
        case .sty: flow.store = flow.y

        case .and, .ora, .eor: combine(opcode.mnemonic, mode, at: pc)

        case .tax: flow.x = flow.a
        case .tay: flow.y = flow.a
        case .txa: flow.a = flow.x
        case .tya: flow.a = flow.y

        // The other register writes clear provenance. Memory read-modify-write
        // instructions claim all the bits they store.
        case .asl, .lsr, .rol, .ror, .inc, .dec:
            if mode == .accumulator { flow.a = .init() }
        case .adc, .sbc, .pla, .slo, .rla, .sre, .rra, .isc, .anc, .alr, .arr, .ane:
            flow.a = .init()
        case .inx, .dex, .tsx, .plx, .sbx: flow.x = .init()
        case .iny, .dey, .ply: flow.y = .init()
        case .lxa, .las:
            flow.a = .init()
            flow.x = .init()
        default: break
        }
    }

    /// Loads from a hi-res byte inherit all its bits.
    private func loadSource(_ mode: AddressingMode, at pc: Int) -> BitFlow.Source {
        switch mode {
        case .immediate, .zeroPage, .zeroPageX, .zeroPageY: return .init()
        default: break
        }
        guard let address = effectiveAddress(mode, at: pc), isPageByte(address), !cpu.ioPages[address >> 8]
        else { return .init() }
        return .init(address: UInt16(address), mask: 0xFF)
    }

    /// Follow bits from A or its operand where the other input leaves them unchanged.
    private func combine(_ op: Mnemonic, _ mode: AddressingMode, at pc: Int) {
        let isAND = op == .and
        let source = flow.a
        if mode == .immediate {
            guard source.mask != 0 else { return }
            let value = cpu.mem[(pc + 1) & 0xFFFF]
            flow.a.mask &= isAND ? value : ~value
            return
        }
        guard let address = effectiveAddress(mode, at: pc), !cpu.ioPages[address >> 8] else {
            flow.a = .init()
            return
        }

        let operandIsPageByte = isPageByte(address)
        let fromOperand: UInt8 = operandIsPageByte ? (isAND ? cpu.a : ~cpu.a) : 0
        if operandIsPageByte && Int(source.address) == address && source.mask != 0 {
            // A bit combined with itself passes through AND and ORA, and disappears in EOR.
            flow.a.mask = (op == .eor ? 0 : source.mask) | (fromOperand & ~source.mask)
            return
        }

        var fromA = source.mask
        if fromA != 0 {
            let value = cpu.mem[address]
            fromA &= isAND ? value : ~value
        }
        if fromOperand == 0 {
            flow.a.mask = fromA
        } else if fromA == 0 {
            flow.a = .init(address: UInt16(address), mask: fromOperand)
        } else {
            // The result has bits from two different bytes.
            flow.a = .init()
        }
    }

    /// The address the instruction at `pc` finds its operand at, from the
    /// registers as they are (nil: it has none in memory).
    private func effectiveAddress(_ mode: AddressingMode, at pc: Int) -> Int? {
        let low = Int(cpu.mem[(pc + 1) & 0xFFFF])
        func word() -> Int { low | Int(cpu.mem[(pc + 2) & 0xFFFF]) << 8 }
        // The pointer of the indirect modes: in the zero page, its high byte wrapping within it.
        func pointer(_ z: Int) -> Int { Int(cpu.mem[z]) | Int(cpu.mem[(z + 1) & 0xFF]) << 8 }
        switch mode {
        case .zeroPage: return low
        case .zeroPageX: return (low + Int(cpu.x)) & 0xFF
        case .zeroPageY: return (low + Int(cpu.y)) & 0xFF
        case .absolute: return word()
        case .absoluteX: return (word() + Int(cpu.x)) & 0xFFFF
        case .absoluteY: return (word() + Int(cpu.y)) & 0xFFFF
        case .indirectX: return pointer((low + Int(cpu.x)) & 0xFF)
        case .indirectY: return (pointer(low) + Int(cpu.y)) & 0xFFFF
        case .zeroPageIndirect: return pointer(low)
        case .implied, .accumulator, .immediate, .indirect, .relative, .absoluteIndexedIndirect: return nil
        }
    }
}
