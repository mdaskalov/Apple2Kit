import Foundation
import MOS6502

/// An Apple ][ or ][+ with 48K and a 16K language card in slot 0, or an
/// Apple //e with 64K (no aux memory: 40 columns), and a Disk II card in
/// slot 6, on the `MOS6502` CPU.
///
/// $0000-$BFFF is the CPU's own flat memory (`cpu.mem`); every page from $C0
/// up goes through `read`/`write` (the CPU's I/O pages): the soft switches,
/// the slot ROMs and the language card's RAM or the ROM at $D000-$FFFF
/// (Docs/Hardware.md).  `run` runs the CPU; the display is drawn from
/// memory when asked (`Screen`).
public nonisolated final class Apple2 {
    public enum Model: String, CaseIterable, Identifiable, Sendable {
        /// Integer BASIC and the original monitor: no autostart, RESET goes
        /// to the monitor (`*`); boot a disk with `C600G` or `6` Ctrl-P.
        case apple2 = "Apple ]["
        /// Applesoft and the autostart monitor: boots the disk in slot 6, or
        /// starts Applesoft (`]`) when there is none.
        case apple2Plus = "Apple ][+"

        /// The unenhanced //e (6502): Applesoft, lower case, its own
        /// firmware at $C100-$CFFF.  64K: no 80 columns yet.
        case apple2e = "Apple //e"

        public var id: String { rawValue }
        /// Its ROM file (`ROMs`): `romName`.rom.
        public var romName: String {
            switch self {
            case .apple2: "apple2"
            case .apple2Plus: "apple2plus"
            case .apple2e: "apple2e"
            }
        }
        /// The ROM's size: 12K for $D000-$FFFF, the //e's 16K for $C000-$FFFF.
        public var romSize: Int { self == .apple2e ? 0x4000 : 0x3000 }
    }

    /// CPU cycles a second (NTSC: 14.31818 MHz × 65 / 912).
    public static let clock = 1_020_484.0
    /// Cycles of one video frame: 65 a line, 262 lines.
    public static let cyclesPerFrame = 65 * 262
    static let diskSlot = 6

    public let model: Model
    public let cpu: CPU6502
    public let disk = DiskII()
    public private(set) var video = VideoMode()
    private let rom: [UInt8]
    private let diskROM: [UInt8]
    private var languageCard = LanguageCard()
    /// The //e's memory and ROM switches.
    private var iie = IIeSwitches()
    var isIIe: Bool { model == .apple2e }

    /// The keyboard's latch: the last key, bit 7 set until $C010 clears it.
    private(set) var keyboard: UInt8 = 0
    /// Keys to type (`type`), one each time the latch is clear.
    private var typeAhead: [UInt8] = []
    private var nextTypedKey: UInt64 = 0
    /// The three push buttons ($C061-$C063).
    public var buttons = [false, false, false]
    /// The four paddles, 0-255 (the timers run 11 cycles a step).
    public var paddles: [UInt8] = [128, 128, 128, 128]
    private var paddleTrigger: UInt64 = 0
    /// Speaker clicks ($C030) so far.
    private(set) var speakerClicks = 0
    /// The CPU cycle of every click since the last `takeClicks`, when not
    /// nil (the app's sound: `SpeakerStream`).
    var clicks: [UInt64]?
    /// The Disk II boot ROM stays out of $C600 until the code reads the
    /// keyboard (`startBASIC`), so the autostart ROM finds no disk to boot.
    private var diskROMHidden = false

    public init(model: Model, rom: [UInt8], diskROM: [UInt8]) {
        precondition(rom.count == model.romSize,
                     "a 12K ROM for $D000-$FFFF (the //e: 16K for $C000-$FFFF)")
        precondition(diskROM.count == 0x100, "the 256-byte Disk II boot ROM")
        self.model = model
        self.rom = rom
        self.diskROM = diskROM
        cpu = CPU6502(memory: [UInt8](repeating: 0, count: 0x10000))
        for page in 0xC0 ... 0xFF { cpu.ioPages[page] = true }
        cpu.ioRead = { [unowned self] in read($0) }
        cpu.ioWrite = { [unowned self] in write($0, $1) }
        powerOn()
    }

    // MARK: power and reset

    /// Switches the machine off and on: RAM cleared, switches as at power-up,
    /// the CPU through the RESET vector (the ][+ boots the disk in drive 1).
    public func powerOn() {
        cpu.mem.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        languageCard = LanguageCard()
        setIIeSwitches(IIeSwitches())
        video = VideoMode()
        keyboard = 0
        typeAhead = []
        disk.reset()
        diskROMHidden = false
        (cpu.a, cpu.x, cpu.y, cpu.sp, cpu.p) = (0, 0, 0, 0xFF, 0x34)
        cpu.reset()
    }

    /// Power cycle into BASIC, whatever is in the drives: the ][+'s Applesoft
    /// (`]`), the ]['s monitor (`*`, Ctrl-B for Integer BASIC).
    public func startBASIC() {
        powerOn()
        diskROMHidden = true
    }

    /// The RESET key (Ctrl-RESET on the ][+): memory stays, the language card
    /// goes back to ROM.
    public func reset() {
        languageCard.reset()
        setIIeSwitches(IIeSwitches())
        video.altCharset = false
        cpu.reset()
    }

    // MARK: running

    /// Runs `cycles` CPU cycles (to the end of the instruction they end in).
    /// Throws when the CPU jams (`CPU6502.CPUError`).
    public func run(cycles: Int) throws {
        let end = cpu.cycles + UInt64(cycles)
        while cpu.cycles < end {
            if !typeAhead.isEmpty { typeNextKey() }
            try cpu.step()
        }
    }

    // MARK: keyboard

    /// A key pressed: its ASCII code (0-127).
    public func press(_ ascii: UInt8) {
        keyboard = ascii | 0x80
    }

    /// Types `text` key by key, as fast as the code takes them.  Newlines are
    /// RETURN; the ][ and ][+ have no lower case (the //e has).
    public func type(_ text: String) {
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            guard var c = scalar.isASCII ? UInt8(scalar.value) : nil else { continue }
            if c == 0x0A { c = 0x0D }
            if c == 0x09 { c = 0x20 }
            if !isIIe, (0x61 ... 0x7A).contains(c) { c -= 0x20 }
            typeAhead.append(c)
        }
    }

    public var isTyping: Bool { !typeAhead.isEmpty }

    // MARK: speaker

    /// The clicks since the last call, in order (empty unless `clicks` is set).
    func takeClicks() -> [UInt64] {
        guard let taken = clicks else { return [] }
        clicks = []
        return taken
    }

    /// The next key of `typeAhead` once the code has taken the last one and
    /// had a moment (2000 cycles) for it.
    private func typeNextKey() {
        guard keyboard & 0x80 == 0, cpu.cycles >= nextTypedKey else { return }
        keyboard = typeAhead.removeFirst() | 0x80
    }

    // MARK: memory map

    private func read(_ a: UInt16) -> UInt8 {
        if a >= 0xD000 {
            return languageCard.readsRAM ? languageCard.ram[languageCard.offset(a)] : rom[Int(a) - 0xD000 + romOffset]
        }
        if a < 0xC000 { return iie.ramRead ? 0 : cpu.mem[Int(a)] }    // //e: no aux memory
        if a < 0xC100 { return io(a, write: false, value: 0) }
        if isIIe, let byte = internalROM(a) { return byte }
        if a >> 8 == 0xC0 + Apple2.diskSlot, disk.hasDisk, !diskROMHidden { return diskROM[Int(a & 0xFF)] }
        return 0                                // empty slots, no $C800 ROM
    }

    private func write(_ a: UInt16, _ value: UInt8) {
        if a >= 0xD000 {
            if languageCard.writesRAM { languageCard.ram[languageCard.offset(a)] = value }
        } else if a < 0xC000 {
            if !iie.ramWrite { cpu.mem[Int(a)] = value }                // //e: no aux memory
        } else if a < 0xC100 {
            _ = io(a, write: true, value: value)
        } else if a == 0xCFFF {
            iie.intC8ROM = false
        }
    }

    /// Where the $D000-$FFFF ROM starts in `rom` (the //e's has $C000-$CFFF first).
    private var romOffset: Int { rom.count - 0x3000 }

    /// The //e's own ROM at $C100-$CFFF, where it is switched in: all of it
    /// (INTCXROM); $C300 (the 80-column firmware) unless SLOTC3ROM, which
    /// also brings in its $C800-$CFFF until $CFFF is touched.  Nil: the slots'.
    private func internalROM(_ a: UInt16) -> UInt8? {
        let byte = rom[Int(a) - 0xC000]
        let page = a >> 8
        defer { if a == 0xCFFF { iie.intC8ROM = false } }
        if iie.intCXROM { return byte }
        if page == 0xC3 {
            guard !iie.slotC3ROM else { return nil }
            iie.intC8ROM = true
            return byte
        }
        return page >= 0xC8 && iie.intC8ROM ? byte : nil
    }

    /// The //e's switches as `new`; RAMRD/RAMWRT send $0200-$BFFF through
    /// `read`/`write` (to aux memory, which isn't there).
    private func setIIeSwitches(_ new: IIeSwitches) {
        let aux = new.ramRead || new.ramWrite
        if aux != (iie.ramRead || iie.ramWrite) {
            for page in 0x02 ..< 0xC0 { cpu.ioPages[page] = aux }
        }
        iie = new
    }

    /// $C000-$C00F written on the //e: switch n/2 off (even) or on (odd).
    private func setIIeSwitch(_ n: Int) {
        let on = n & 1 != 0
        var s = iie
        switch n >> 1 {
        case 0: s.store80 = on
        case 1: s.ramRead = on
        case 2: s.ramWrite = on
        case 3: s.intCXROM = on
        case 4: s.altZP = on                    // no aux memory: the zero page stays
        case 5: s.slotC3ROM = on
        case 6: s.col80 = on
        default: video.altCharset = on
        }
        setIIeSwitches(s)
    }

    /// $C011-$C01F on the //e: a switch in bit 7, the last key below.
    private func iieStatus(_ n: Int) -> UInt8 {
        let on: Bool
        switch n {
        case 0x1: on = languageCard.bank2
        case 0x2: on = languageCard.readsRAM
        case 0x3: on = iie.ramRead
        case 0x4: on = iie.ramWrite
        case 0x5: on = iie.intCXROM
        case 0x6: on = iie.altZP
        case 0x7: on = iie.slotC3ROM
        case 0x8: on = iie.store80
        case 0x9: on = cpu.cycles % UInt64(Apple2.cyclesPerFrame) < 192 * 65    // not in the vertical blank
        case 0xA: on = video.text
        case 0xB: on = video.mixed
        case 0xC: on = video.page2
        case 0xD: on = video.hires
        case 0xE: on = video.altCharset
        default: on = iie.col80
        }
        return (on ? 0x80 : 0) | keyboard & 0x7F
    }

    /// $C000-$C0FF: a read, or a write of `value`; both throw the switches.
    private func io(_ a: UInt16, write: Bool, value: UInt8) -> UInt8 {
        let low = Int(a & 0xFF)
        switch low >> 4 {
        case 0x0:
            if write && isIIe { setIIeSwitch(low) }
            if keyboard & 0x80 == 0 { diskROMHidden = false }   // BASIC waits for a key: the slot scan is over
            return keyboard
        case 0x1:
            if isIIe && low != 0x10 { return write ? 0 : iieStatus(low & 0xF) }
            if keyboard & 0x80 != 0 { nextTypedKey = cpu.cycles + 2000 }
            keyboard &= 0x7F
            return keyboard
        case 0x3:
            speakerClicks += 1
            clicks?.append(cpu.cycles)
        case 0x5:
            // the //e's 80STORE: PAGE2 picks aux memory (not there), not the page shown
            if !(iie.store80 && low & 0xE == 4) { video.set(low & 0xF) }
        case 0x6:
            switch low & 7 {
            case 1 ... 3: return buttons[(low & 7) - 1] ? 0x80 : 0
            case 4 ... 7:
                return cpu.cycles &- paddleTrigger < UInt64(paddles[(low & 7) - 4]) * 11 ? 0x80 : 0
            default: return 0                   // cassette in
            }
        case 0x7:
            paddleTrigger = cpu.cycles
        case 0x8:
            languageCard.access(low, write: write)
        case 0x8 + Apple2.diskSlot:
            return disk.access(low & 0xF, write: write, value: value, cycles: cpu.cycles)
        default:
            break                               // cassette out, strobe, empty slots
        }
        return 0
    }

    // MARK: inspecting

    /// The 16K of the language card: $D000 bank 1, $D000 bank 2, $E000-$FFFF.
    public var languageCardRAM: [UInt8] { languageCard.ram }

    /// What the CPU reads at `address`, without throwing a switch ($C0xx
    /// reads as 0).
    public func peek(_ address: UInt16) -> UInt8 {
        address >= 0xD000 ? read(address) : address >= 0xC000 ? 0 : cpu.mem[Int(address)]
    }

    var languageCardState: String { languageCard.description }
}

/// The display switches $C050-$C057 (and the //e's ALTCHARSET).
public nonisolated struct VideoMode: Equatable, Sendable {
    public var text = true
    public var mixed = false
    public var page2 = false
    public var hires = false
    /// The //e's second character set: inverse lower case for flashing.
    public var altCharset = false

    mutating func set(_ n: Int) {
        switch n {
        case 0: text = false
        case 1: text = true
        case 2: mixed = false
        case 3: mixed = true
        case 4: page2 = false
        case 5: page2 = true
        case 6: hires = false
        case 7: hires = true
        default: break                          // annunciators
        }
    }
}

/// The //e's switches for memory and ROM ($C000-$C00B written, read at
/// $C013-$C018).  The //e here has no aux memory: RAMRD reads nothing,
/// RAMWRT writes nowhere, ALTZP and 80STORE change nothing.
nonisolated struct IIeSwitches {
    var store80 = false, ramRead = false, ramWrite = false, altZP = false
    var intCXROM = false, slotC3ROM = false, col80 = false
    /// $C800-$CFFF is the internal ROM's (since $C3xx was read), until $CFFF.
    var intC8ROM = false
}

/// The 16K language card (slot 0): RAM for $D000-$FFFF, $D000-$DFFF twice
/// (banks 1 and 2), read in place of the ROM or not, write-enabled or not, by
/// $C080-$C08F (Docs/Hardware.md).
nonisolated struct LanguageCard: CustomStringConvertible {
    /// $0000: $D000 bank 1, $1000: $D000 bank 2, $2000: $E000-$FFFF.
    var ram = [UInt8](repeating: 0, count: 0x4000)
    private(set) var readsRAM = false
    private(set) var writesRAM = true
    private(set) var bank2 = true
    /// An odd switch was read: a second read in a row enables writing.
    private var preWrite = false

    /// As after RESET: read ROM, write RAM, bank 2.
    mutating func reset() {
        readsRAM = false
        writesRAM = true
        bank2 = true
        preWrite = false
    }

    /// $C080 + n: bit 3 the bank (0: bank 2); bits 0-1 equal: read RAM;
    /// bit 0 set: two reads in a row enable writing; bit 0 clear disables it.
    mutating func access(_ n: Int, write: Bool) {
        bank2 = n & 8 == 0
        readsRAM = n & 1 == n >> 1 & 1
        if n & 1 != 0 {
            if !write && preWrite { writesRAM = true }
            preWrite = !write
        } else {
            writesRAM = false
            preWrite = false
        }
    }

    @inline(__always) func offset(_ a: UInt16) -> Int {
        a >= 0xE000 ? Int(a) - 0xC000 : Int(a) - (bank2 ? 0xC000 : 0xD000)
    }

    var description: String {
        "LC: read \(readsRAM ? "RAM" : "ROM"), write \(writesRAM ? "RAM" : "–"), bank \(bank2 ? 2 : 1)"
    }
}
