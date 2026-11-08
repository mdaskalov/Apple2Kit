import Foundation
import MOS6502

/// An Apple ][ or ][+ with 48K and a 16K language card in slot 0, or an
/// Apple //e with 64K (no aux memory: 40 columns), and a Disk II card in
/// slot 6, on the `MOS6502` CPU.
///
/// $0000-$BFFF is the CPU's own flat memory (`cpu.mem`); $C000-$CFFF goes
/// through `read`/`write` (the CPU's I/O pages): the soft switches and the
/// slot ROMs; $D000-$FFFF too while the ROM is read there or the language
/// card's RAM is write-protected – while that RAM is read and written, it
/// lies in `cpu.mem` (`mapLanguageCard`), as fast as the rest
/// (Docs/Hardware.md).  `run` runs the CPU; the display is drawn from
/// memory when asked (`Screen`).
///
/// Without ROMs (`init` with nil) the machine is a host's: the language
/// card's RAM is always read and written ($C080-$C08F pick the bank only),
/// the slots' ROM pages are empty but the cards' (`insert`), nothing
/// boots – the host loads memory (`load`) and sets the CPU going.  The
/// text page starts blank (spaces), not as zeros (inverse `@`).
///
/// This is the hardware alone, without a clock, sound or UI (headless:
/// `Data/headless.sh`).  An app holds an `Apple2`, which runs one of these
/// in real time (`Apple2.machine`).
public nonisolated final class Apple2Machine {
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
    public private(set) var disk = DiskII()
    public private(set) var video = VideoMode()
    /// Nil: none (the language card's RAM in its place).
    private let rom: [UInt8]?
    private let diskROM: [UInt8]?
    private var languageCard: LanguageCard
    /// The $D000 bank of the language card's RAM that lies in `cpu.mem`
    /// with $E000-$FFFF (true: bank 2); nil: none, `languageCard.ram` holds
    /// it all and the CPU reaches $D000-$FFFF through `read`/`write`.
    private var mappedBank2: Bool?
    /// The cards in slots 1-7 (`insert`); the Disk II in slot 6 is the machine's.
    public private(set) var cards = [Apple2Card?](repeating: nil, count: 8)
    /// The host's own soft switches (`io`): called at every access to
    /// $C000-$C0FF before the machine's own handling, with the address,
    /// whether it writes, and the value written.  A value: the access is the
    /// host's, a read returns it and the machine does nothing; nil: the
    /// machine's.
    public var ioHook: ((_ address: UInt16, _ write: Bool, _ value: UInt8) -> UInt8?)?
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
    public var clicks: [UInt64]?
    /// The Disk II boot ROM stays out of $C600 until the code reads the
    /// keyboard (`startBASIC`), so the autostart ROM finds no disk to boot.
    private var diskROMHidden = false

    /// A machine of `model`; `rom` nil: none, the language card's RAM in its
    /// place (the host's machine, see above); `diskROM` nil: the Disk II
    /// doesn't boot.
    public init(model: Model, rom: [UInt8]?, diskROM: [UInt8]?) {
        precondition(rom.map { $0.count == model.romSize } ?? true,
                     "a 12K ROM for $D000-$FFFF (the //e: 16K for $C000-$FFFF)")
        precondition(diskROM.map { $0.count == 0x100 } ?? true, "the 256-byte Disk II boot ROM")
        self.model = model
        self.rom = rom
        self.diskROM = diskROM
        languageCard = LanguageCard(ramOnly: rom == nil)
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
        unmapLanguageCard()
        cpu.mem.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        if rom == nil { cls() }                 // no ROM clears the screen
        languageCard = LanguageCard(ramOnly: rom == nil)
        mapLanguageCard()
        for slot in 1 ... 7 where cards[slot] != nil { putROMPage(slot) }
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
        mapLanguageCard()
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
    public func takeClicks() -> [UInt64] {
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
            guard !languageCard.readsRAM, let rom else { return languageCard.ram[languageCard.offset(a)] }
            return rom[Int(a) - 0xD000 + romOffset]
        }
        if a < 0xC000 { return iie.ramRead ? 0 : cpu.mem[Int(a)] }    // //e: no aux memory
        if a < 0xC100 { return io(a, write: false, value: 0) }
        if isIIe, let byte = internalROM(a) { return byte }
        let slot = Int(a >> 8) - 0xC0
        if slot < 8, cards[slot] != nil { return cpu.mem[Int(a)] }     // its ROM page (`insert`)
        if slot == Apple2Machine.diskSlot, disk.hasDisk, !diskROMHidden, let diskROM { return diskROM[Int(a & 0xFF)] }
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
    private var romOffset: Int { (rom?.count ?? 0x3000) - 0x3000 }

    /// The //e's own ROM at $C100-$CFFF, where it is switched in: all of it
    /// (INTCXROM); $C300 (the 80-column firmware) unless SLOTC3ROM, which
    /// also brings in its $C800-$CFFF until $CFFF is touched.  Nil: the slots'.
    private func internalROM(_ a: UInt16) -> UInt8? {
        guard let rom else { return nil }
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
        case 0x9: on = cpu.cycles % UInt64(Apple2Machine.cyclesPerFrame) < 192 * 65    // not in the vertical blank
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
        if let ioHook, let byte = ioHook(a, write, value) { return byte }
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
            mapLanguageCard()
        case 0x8 + Apple2Machine.diskSlot:
            return disk.access(low & 0xF, write: write, value: value, cycles: cpu.cycles)
        case 0x9 ... 0xF:
            return cards[(low >> 4) - 8]?.access(low & 0xF, write: write, value: value, cycles: cpu.cycles) ?? 0
        default:
            break                               // cassette out, strobe
        }
        return 0
    }

    // MARK: inspecting

    /// The 16K of the language card: $D000 bank 1, $D000 bank 2, $E000-$FFFF.
    public var languageCardRAM: [UInt8] {
        guard let bank2 = mappedBank2 else { return languageCard.ram }
        var ram = languageCard.ram
        ram.replaceSubrange(bank2 ? 0x1000 ..< 0x2000 : 0 ..< 0x1000, with: cpu.mem[0xD000 ..< 0xE000])
        ram.replaceSubrange(0x2000 ..< 0x4000, with: cpu.mem[0xE000 ..< 0x10000])
        return ram
    }

    /// The language card's $D000 bank selected: 1 or 2.
    public var languageCardBank: Int { languageCard.bank2 ? 2 : 1 }

    /// The language card's RAM is read at $D000-$FFFF (not the ROM).
    public var readsLanguageCardRAM: Bool { languageCard.readsRAM }

    /// What the CPU reads at `address`, without throwing a switch ($C0xx
    /// reads as 0).
    public func peek(_ address: UInt16) -> UInt8 {
        address >= 0xD000 ? (cpu.ioPages[Int(address >> 8)] ? read(address) : cpu.mem[Int(address)])
            : address >= 0xC000 ? 0 : cpu.mem[Int(address)]
    }

    var languageCardState: String { languageCard.description }

    /// It has its model's ROM (else it's a host's machine, see above).
    public var hasROM: Bool { rom != nil }

    // MARK: the host's

    /// Puts `memory` in main RAM ($0000-$BFFF; a 64K image's rest is left
    /// out) and `languageCard` (16K, as `languageCardRAM`) in the language
    /// card's RAM; the switches stay.
    public func load(memory: [UInt8], languageCard ram: [UInt8]) {
        precondition(memory.count >= 0xC000 && ram.count == 0x4000, "48K (or 64K) of main RAM and the card's 16K")
        unmapLanguageCard()
        cpu.mem.replaceSubrange(0 ..< 0xC000, with: memory[0 ..< 0xC000])
        languageCard.ram = ram
        mapLanguageCard()
    }

    /// Puts `card` in `slot` (1-7, not the Disk II's 6), or takes the card
    /// there out (nil): its ROM page is read at $Cn00-$CnFF, its switches
    /// are $C080 + slot × 16 on.
    public func insert(_ card: Apple2Card?, slot: Int) {
        precondition((1 ... 7).contains(slot) && slot != Apple2Machine.diskSlot, "slots 1-7 but the Disk II's")
        cards[slot] = card
        putROMPage(slot)
    }

    /// A card's ROM page lies in `cpu.mem` at $Cn00 (the CPU reads it
    /// through `read`, a host's code there as on the Apple): an empty slot's
    /// is zeros.
    private func putROMPage(_ slot: Int) {
        let page = 0xC000 | slot << 8
        let bytes = cards[slot]?.romPage ?? []
        precondition(bytes.isEmpty || bytes.count == 0x100, "a card's ROM page is 256 bytes")
        cpu.mem.replaceSubrange(page ..< page + 0x100, with: bytes.isEmpty ? [UInt8](repeating: 0, count: 0x100) : bytes)
    }

    /// An independent machine in the same state: memory, the switches, the
    /// devices, the drives and their disks, the CPU's registers and cycles.
    /// The cards are the same (a card keeps its own state); the host's
    /// `ioHook` and the CPU's traps and watches aren't copied.
    public func copy() -> Apple2Machine {
        let c = Apple2Machine(model: model, rom: rom, diskROM: diskROM)
        c.cpu.mem = cpu.mem
        c.cpu.ioPages = cpu.ioPages
        (c.cpu.a, c.cpu.x, c.cpu.y, c.cpu.sp, c.cpu.p, c.cpu.pc, c.cpu.cycles) = (cpu.a, cpu.x, cpu.y, cpu.sp, cpu.p, cpu.pc, cpu.cycles)
        c.cpu.stopsAtBRK = cpu.stopsAtBRK
        c.languageCard = languageCard
        c.mappedBank2 = mappedBank2
        c.cards = cards
        c.disk = disk.copy()
        c.video = video
        c.iie = iie
        c.keyboard = keyboard
        c.typeAhead = typeAhead
        c.nextTypedKey = nextTypedKey
        c.buttons = buttons
        c.paddles = paddles
        c.paddleTrigger = paddleTrigger
        c.speakerClicks = speakerClicks
        c.clicks = clicks
        c.diskROMHidden = diskROMHidden
        return c
    }

    // MARK: the language card in flat memory

    /// The language card's RAM in `cpu.mem` while it is read and written
    /// (the selected $D000 bank and $E000-$FFFF; $D0-$FF no I/O pages): the
    /// CPU reaches it at full speed, and a host reads it there like the rest
    /// of memory.  Otherwise `languageCard.ram` holds it and the CPU goes
    /// through `read`/`write` (the ROM, or RAM write-protected).  Called after
    /// every switch of the card; a bank switch swaps $D000-$DFFF.
    private func mapLanguageCard() {
        let flat = languageCard.readsRAM && languageCard.writesRAM
        let bank2 = languageCard.bank2
        if let mapped = mappedBank2 {
            if flat && mapped == bank2 { return }
            languageCard.ram.replaceSubrange(mapped ? 0x1000 ..< 0x2000 : 0 ..< 0x1000, with: cpu.mem[0xD000 ..< 0xE000])
            if !flat { unmapLanguageCard() }
        }
        guard flat else { return }
        cpu.mem.replaceSubrange(0xD000 ..< 0xE000, with: languageCard.ram[bank2 ? 0x1000 ..< 0x2000 : 0 ..< 0x1000])
        if mappedBank2 == nil {
            cpu.mem.replaceSubrange(0xE000 ..< 0x10000, with: languageCard.ram[0x2000 ..< 0x4000])
            for page in 0xD0 ... 0xFF { cpu.ioPages[page] = false }
        }
        mappedBank2 = bank2
    }

    /// The language card's RAM back from `cpu.mem` into `languageCard.ram`,
    /// $D0-$FF I/O pages again.
    private func unmapLanguageCard() {
        guard let bank2 = mappedBank2 else { return }
        languageCard.ram.replaceSubrange(bank2 ? 0x1000 ..< 0x2000 : 0 ..< 0x1000, with: cpu.mem[0xD000 ..< 0xE000])
        languageCard.ram.replaceSubrange(0x2000 ..< 0x4000, with: cpu.mem[0xE000 ..< 0x10000])
        for page in 0xD0 ... 0xFF { cpu.ioPages[page] = true }
        mappedBank2 = nil
    }

    // MARK: text on the screen

    /// Fills text page 1 ($0400-$07FF) with spaces.
    public func cls() {
        cpu.mem.replaceSubrange(0x400 ..< 0x800, with: repeatElement(0xA0, count: 0x400))
    }

    /// Writes `text` on text page 1, row `y` (0-23) from column `x` (nil:
    /// centred), cut off at the row's ends; a character past ASCII (or a
    /// control character) as `?`.  `uppercased` nil: on the ][ and ][+,
    /// which have no lower case.  `cls`: the screen cleared first.  It shows
    /// while the screen is in text mode (as at power-on).
    public func print(_ text: String, atX x: Int? = nil, y: Int = 12, uppercased: Bool? = nil, cls: Bool = true) {
        if cls { self.cls() }
        guard (0 ..< 24).contains(y) else { return }
        let text = (uppercased ?? !isIIe) ? text.uppercased() : text
        var bytes = text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 ? UInt8($0.value) | 0x80 : 0xBF }
        let x = x ?? (40 - bytes.count) / 2
        if x < 0 { bytes.removeFirst(min(-x, bytes.count)) }
        let column = max(x, 0)
        let count = min(bytes.count, 40 - column)
        guard count > 0 else { return }
        let address = Screen.textAddress(row: y, page2: false) + column
        cpu.mem.replaceSubrange(address ..< address + count, with: bytes.prefix(count))
    }
}

/// A card in a slot of an `Apple2Machine` (`insert`): its ROM page at $Cn00-$CnFF
/// and its 16 switches at $C080 + slot × 16 ($C0n0-$C0nF, n = slot + 8).  A
/// host can run the card's firmware as its own code where the CPU gets there
/// (the CPU's traps).
public nonisolated protocol Apple2Card: AnyObject {
    /// The 256 bytes at $Cn00-$CnFF.
    var romPage: [UInt8] { get }
    /// Switch `n` (0-15) read, or written with `value`, at CPU cycle `cycles`.
    func access(_ n: Int, write: Bool, value: UInt8, cycles: UInt64) -> UInt8
}

public nonisolated extension Apple2Card {
    /// No switches: they read 0.
    func access(_ n: Int, write: Bool, value: UInt8, cycles: UInt64) -> UInt8 { 0 }
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
    /// No ROM behind it: always read and written, the switches pick the bank only.
    let ramOnly: Bool
    private(set) var readsRAM: Bool
    private(set) var writesRAM = true
    private(set) var bank2 = true
    /// An odd switch was read: a second read in a row enables writing.
    private var preWrite = false

    init(ramOnly: Bool) {
        self.ramOnly = ramOnly
        readsRAM = ramOnly
    }

    /// As after RESET: read ROM (with none: RAM), write RAM, bank 2.
    mutating func reset() {
        readsRAM = ramOnly
        writesRAM = true
        bank2 = true
        preWrite = false
    }

    /// $C080 + n: bit 3 the bank (0: bank 2); bits 0-1 equal: read RAM;
    /// bit 0 set: two reads in a row enable writing; bit 0 clear disables it.
    mutating func access(_ n: Int, write: Bool) {
        bank2 = n & 8 == 0
        guard !ramOnly else { return }
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
