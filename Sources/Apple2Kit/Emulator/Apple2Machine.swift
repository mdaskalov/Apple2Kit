import Foundation
import MOS6502

/// An Apple ][ or ][+ with 48K and a 16K language card in slot 0, or an
/// Apple //e (unenhanced, or enhanced with a 65C02) with 128K: an extended
/// 80-column card in its aux slot; and a Disk II card in slot 6, on the
/// `MOS6502` CPU.
///
/// $0000-$BFFF is the CPU's own flat memory (`cpu.mem`); $C000-$CFFF goes
/// through `read`/`write` (the CPU's I/O pages): the soft switches and the
/// slot ROMs; $D000-$FFFF too while the ROM is read there or the language
/// card's RAM is write-protected – while that RAM is read and written, it
/// lies in `cpu.mem` (`mapLanguageCard`), as fast as the rest.  On the //e
/// each page of `cpu.mem` holds the bank (main or aux) the CPU reads there,
/// and its writes go through `write` when they go to the other
/// (`mapAuxMemory`; Docs/Hardware.md).  `run` runs the CPU; the display is
/// drawn from memory when asked (`Screen`).
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
        /// firmware at $C100-$CFFF; 128K, 80 columns, double hi-res.
        case apple2e = "Apple //e"
        /// The enhanced //e: the //e with a 65C02 and its ROM (MouseText in
        /// the alternate character set, lower case in Applesoft).
        case apple2eEnhanced = "Apple //e Enhanced"

        public var id: String { rawValue }
        /// Its ROM file (`ROMs`): `romName`.rom.
        public var romName: String {
            switch self {
            case .apple2: "apple2"
            case .apple2Plus: "apple2plus"
            case .apple2e: "apple2e"
            case .apple2eEnhanced: "apple2ee"
            }
        }
        /// The ROM's size: 12K for $D000-$FFFF, the //e's 16K for $C000-$FFFF.
        public var romSize: Int { isIIe ? 0x4000 : 0x3000 }
        /// A //e: lower case, 128K, 80 columns.
        public var isIIe: Bool { self == .apple2e || self == .apple2eEnhanced }
        /// Its CPU: the enhanced //e's is a 65C02.
        public var cpuVariant: CPU6502.Variant { self == .apple2eEnhanced ? .cmos65C02 : .nmos6502 }
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
    /// The //e (`Model.isIIe`): aux memory, 80 columns.
    let isIIe: Bool
    /// The //e's two banks below $C000, main at 0, aux at $C000 (`mapAuxMemory`):
    /// the bank of a page that `cpu.mem` holds is stale here.
    private var banks: [UInt8]
    /// For each page below $C000, the bank `cpu.mem` holds: aux (true) or main.
    private var auxInMemory = [Bool](repeating: false, count: 0xC0)
    /// The language card's RAM of the bank ALTZP doesn't pick (aux while it is
    /// off, main while on): `languageCard.ram` is the one used.
    private var otherLanguageCardRAM = [UInt8](repeating: 0, count: 0x4000)

    /// The keyboard: its latch, the keys held, the //e's repeat (`keyDown`).
    public private(set) var keyboard: Keyboard
    /// Keys to type (`type`), one each time the latch is clear.
    private var typeAhead: [UInt8] = []
    private var nextTypedKey: UInt64 = 0
    /// The paddles, the push buttons and a joystick (`GamePort`).
    public var gamePort = GamePort()
    /// The mouse card in slot 4 (`MouseCard`), there while `mouseEnabled`.
    public private(set) var mouse = MouseCard()
    /// The mouse card is in slot 4: its ROM page there, its firmware run.
    /// Put in, it starts afresh (as at power-on).
    public var mouseEnabled = false {
        didSet {
            guard mouseEnabled != oldValue else { return }
            if mouseEnabled { resetMouse() }
            putROMPage(MouseCard.slot)
            for call in MouseCard.Call.allCases { refreshTrap(call.entry) }
        }
    }
    /// How many vertical blanks have begun (`step`, for the mouse card's interrupt).
    private var verticalBlanks: UInt64 = 0
    /// The hooks (`addHook`, Hooks.swift): Swift where the CPU reaches an
    /// address, each with a switch if it has a name.
    var hooks = Hooks()
    /// The shadow copy of the hi-res pages, $2000-$5FFF of main memory
    /// (Shadow.swift), while `keepsShadow`.
    var shadowBytes = [UInt8](repeating: 0, count: Apple2Machine.shadowSize)
    /// Natives tracing their code (`addNative`) that keep its writes out of
    /// the shadow (`NativeFlags.ignoresGraphics`).
    var shadowSuspended = 0
    /// The shadow follows main memory's writes to $2000-$5FFF (Shadow.swift):
    /// switched on, it starts as a copy of the pages.
    public var keepsShadow = false {
        didSet {
            guard keepsShadow != oldValue else { return }
            for page in Apple2Machine.shadowPages { cpu.watchedPages[page] = keepsShadow }
            if keepsShadow { syncShadow() }
        }
    }
    /// Called with the address of every write the shadow takes, when set:
    /// a host following what the code draws outside its natives.
    public var onShadowWrite: ((Int) -> Void)?
    /// The host's object, for its hooks: a host keeping its own state with
    /// the machine (its devices, what its natives found) sets itself here,
    /// and its hooks find it (`machine.host as? MyHost`).  Not copied: a
    /// host's copy sets itself on the machine's copy.  Not kept either: the
    /// host keeps the machine, and must outlive it or set this to nil.  (A
    /// weak reference would move the host's reference counts to a side
    /// table and make each retain of it several times slower.)
    public unowned(unsafe) var host: AnyObject?
    /// The host's traps it sets itself (`CPU6502.traps`), asked where the
    /// CPU reaches one that no hook took: true, it handled the instruction
    /// there.  A hook put in or taken out at the same address sets the trap
    /// as the hooks need it.
    public var onTrap: ((UInt16) -> Bool)?
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
        isIIe = model.isIIe
        banks = [UInt8](repeating: 0, count: model.isIIe ? 0x18000 : 0)
        languageCard = LanguageCard(ramOnly: rom == nil)
        keyboard = Keyboard(repeats: model.isIIe)
        cpu = CPU6502(memory: [UInt8](repeating: 0, count: 0x10000), variant: model.cpuVariant)
        for page in 0xC0 ... 0xFF { cpu.ioPages[page] = true }
        cpu.ioRead = { [unowned self] in read($0) }
        cpu.ioWrite = { [unowned self] in write($0, $1) }
        cpu.onTrap = { [unowned self] pc in runMouseFirmware(at: pc) || runHooks(at: pc) || onTrap?(pc) == true }
        // The kit's: the shadow's (`keepsShadow` watches $20-$5F).
        cpu.onWrite = { [unowned self] a, _, value in shadowWrite(a, value) }
        powerOn()
    }

    // MARK: power and reset

    /// Switches the machine off and on: RAM cleared, switches as at power-up,
    /// the CPU through the RESET vector (the ][+ boots the disk in drive 1).
    public func powerOn() {
        unmapLanguageCard()
        cpu.mem.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        banks.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        auxInMemory = [Bool](repeating: false, count: 0xC0)
        for page in 0 ..< 0xC0 { cpu.ioWritePages[page] = false }
        iie = IIeSwitches()
        otherLanguageCardRAM = [UInt8](repeating: 0, count: 0x4000)
        if rom == nil { cls() }                 // no ROM clears the screen
        languageCard = LanguageCard(ramOnly: rom == nil)
        mapLanguageCard()
        for slot in 1 ... 7 where hasCard(slot) { putROMPage(slot) }     // the mouse card's too
        video = VideoMode()
        keyboard = Keyboard(repeats: isIIe)
        resetMouse()
        typeAhead = []
        disk.reset()
        diskROMHidden = false
        (cpu.a, cpu.x, cpu.y, cpu.sp, cpu.p) = (0, 0, 0, 0xFF, 0x34)
        cpu.reset()
        if keepsShadow { syncShadow() }
    }

    /// Power cycle into BASIC, whatever is in the drives: the ][+'s Applesoft
    /// (`]`), the ]['s monitor (`*`, Ctrl-B for Integer BASIC).
    public func startBASIC() {
        powerOn()
        diskROMHidden = true
    }

    /// The RESET key (Ctrl-RESET on the ][+): memory stays, the language card
    /// goes back to ROM; on the //e main memory, 40 columns, the first
    /// character set.
    public func reset() {
        languageCard.reset()
        mapLanguageCard()
        setIIeSwitches(IIeSwitches())
        video.altCharset = false
        video.col80 = false
        video.resetRGB()
        cpu.reset()
    }

    // MARK: running

    /// Runs `cycles` CPU cycles (to the end of the instruction they end in).
    /// Throws when the CPU jams (`CPU6502.CPUError`).
    public func run(cycles: Int) throws {
        let end = cpu.cycles + UInt64(cycles)
        while cpu.cycles < end {
            if !typeAhead.isEmpty { typeNextKey() }
            try step()
        }
    }

    /// One instruction, an interrupt first if one is waiting: the IRQ line
    /// (the mouse card's) taken unless I is set.  A host running the CPU
    /// itself steps here, not `cpu.step`, for the interrupts.
    @inline(__always) public func step() throws {
        if mouseEnabled { serveMouseLine() }
        try cpu.step()
    }

    /// The mouse card's vertical blank interrupt, and its IRQ line.
    private func serveMouseLine() {
        if mouse.interruptsAtVBL {
            // a vertical blank begins at line 192 of each frame
            let frame = UInt64(Apple2Machine.cyclesPerFrame), start = UInt64(192 * 65)
            let blanks = (cpu.cycles + frame - start) / frame
            if blanks != verticalBlanks {
                verticalBlanks = blanks
                mouse.verticalBlank()
            }
        }
        if mouse.irq { cpu.irq() }
    }

    // MARK: the mouse card

    /// The mouse moved by (dx, dy) of the card's counts, y down.
    public func moveMouse(dx: Int, dy: Int) {
        mouse.move(dx: dx, dy: dy)
    }

    /// The mouse's button pressed or let go.
    public func mouseButton(down: Bool) {
        mouse.set(button: down)
    }

    /// A program's own way with the mouse's button (`MouseCard.reportsClickOnce`).
    public var mouseReportsClickOnce: Bool {
        get { mouse.reportsClickOnce }
        set { mouse.reportsClickOnce = newValue }
    }

    /// The card as at power-on, the host's `reportsClickOnce` kept.
    private func resetMouse() {
        let clickOnce = mouse.reportsClickOnce
        mouse = MouseCard()
        mouse.reportsClickOnce = clickOnce
    }

    /// The firmware's routine at `pc`, while the card is in: run, and
    /// returned from like RTS, the carry clear or set.
    private func runMouseFirmware(at pc: UInt16) -> Bool {
        guard mouseEnabled, let call = MouseCard.Call.allCases.first(where: { $0.entry == pc }) else { return false }
        let carry = mouse.run(call, a: cpu.a, mem: &cpu.mem)
        cpu.p = carry ? cpu.p | CPU6502.Flag.carry : cpu.p & ~CPU6502.Flag.carry
        cpu.returnFromSubroutine()
        return true
    }

    // MARK: keyboard

    /// A key typed: its ASCII code (0-127) in the latch, as from a key
    /// pressed and let go at once (it doesn't repeat).
    public func press(_ ascii: UInt8) {
        keyboard.press(ascii)
    }

    /// Key `id` (the host's own number for it) went down, typing `ascii`
    /// (0-127).  It is down until `keyUp`: the //e's any-key-down, and its
    /// repeat (`Keyboard`).  The host's own repeats are left out.
    public func keyDown(_ ascii: UInt8, id: Int) {
        keyboard.keyDown(ascii, id: id, at: cpu.cycles)
    }

    /// Key `id` went up.
    public func keyUp(id: Int) {
        keyboard.keyUp(id: id)
    }

    /// Every key up: the host lost the keyboard.
    public func releaseKeys() {
        keyboard.releaseAll()
    }

    /// $C000 read at `cycle` (by a host's routine in place of the code):
    /// the latch, a held key typed again if it repeated.
    public func readKeyboard(at cycle: UInt64) -> UInt8 {
        keyboard.update(at: cycle)
        return keyboard.latch
    }

    /// $C010 at `cycle`: the strobe cleared.  The //e reads any-key-down in
    /// bit 7 and the key below.
    @discardableResult
    public func clearKeyStrobe(at cycle: UInt64) -> UInt8 {
        keyboard.update(at: cycle)
        if keyboard.latch & 0x80 != 0 { nextTypedKey = cycle + 2000 }
        keyboard.latch &= 0x7F
        return (isIIe && keyboard.anyKeyDown ? 0x80 : 0) | keyboard.latch
    }

    // MARK: game port

    /// $C070 at `cycle` (by a host's routine in place of the code): the
    /// paddles' timers start (`GamePort`).
    public func triggerPaddles(at cycle: UInt64) {
        gamePort.trigger(at: cycle)
    }

    /// Paddle `n`'s timer runs at `cycle` ($C064 + n, bit 7).
    public func paddleRunning(_ n: Int, at cycle: UInt64) -> Bool {
        gamePort.running(n, at: cycle)
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
        guard keyboard.latch & 0x80 == 0, cpu.cycles >= nextTypedKey else { return }
        keyboard.press(typeAhead.removeFirst())
    }

    // MARK: memory map

    private func read(_ a: UInt16) -> UInt8 {
        if a >= 0xD000 {
            guard !languageCard.readsRAM, let rom else { return languageCard.ram[languageCard.offset(a)] }
            return rom[Int(a) - 0xD000 + romOffset]
        }
        if a < 0xC000 { return cpu.mem[Int(a)] }                      // a host's I/O page
        if a < 0xC100 { return io(a, write: false, value: 0) }
        if isIIe, let byte = internalROM(a) { return byte }
        let slot = Int(a >> 8) - 0xC0
        if slot < 8, hasCard(slot) { return cpu.mem[Int(a)] }         // its ROM page (`insert`)
        if slot == Apple2Machine.diskSlot, disk.hasDisk, !diskROMHidden, let diskROM { return diskROM[Int(a & 0xFF)] }
        return 0                                // empty slots, no $C800 ROM
    }

    private func write(_ a: UInt16, _ value: UInt8) {
        if a >= 0xD000 {
            if languageCard.writesRAM { languageCard.ram[languageCard.offset(a)] = value }
        } else if a < 0xC000 {
            let page = Int(a >> 8)
            let aux = isIIe && banks(of: page).write
            if aux == (isIIe && auxInMemory[page]) {                    // a host's I/O page
                cpu.mem[Int(a)] = value
            } else {
                banks[(aux ? 0xC000 : 0) + Int(a)] = value                // the //e: the bank not in `cpu.mem`
            }
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

    /// The //e's switches as `new`, memory mapped by them: ALTZP swaps the
    /// language card's RAM for the other bank's.
    private func setIIeSwitches(_ new: IIeSwitches) {
        let swapsCard = new.altZP != iie.altZP
        if swapsCard { unmapLanguageCard() }
        iie = new
        if swapsCard {
            swap(&languageCard.ram, &otherLanguageCardRAM)
            mapLanguageCard()
        }
        mapAuxMemory()
    }

    // MARK: the //e's aux memory

    /// The banks page `page` (below $C0) is read from and written to, aux
    /// (true) or main: the zero page and the stack by ALTZP; with 80STORE the
    /// text page 1 ($04-$07), and hi-res page 1 ($20-$3F) while HIRES is on,
    /// by PAGE2; the rest by RAMRD and RAMWRT.
    @inline(__always) private func banks(of page: Int) -> (read: Bool, write: Bool) {
        if page < 0x02 { return (iie.altZP, iie.altZP) }
        if iie.store80, page >= 0x04 && page < 0x08 || video.hires && page >= 0x20 && page < 0x40 {
            return (video.page2, video.page2)
        }
        return (iie.ramRead, iie.ramWrite)
    }

    /// After a switch of the //e's memory: each page of `cpu.mem` below $C000
    /// holds the bank the CPU reads there (a page whose bank changed swapped
    /// with `banks`), and its writes go through `write` when they go to the
    /// other bank (the CPU's `ioWritePages`).  Code reading main memory and
    /// writing aux runs as fast as any.
    private func mapAuxMemory() {
        guard isIIe else { return }
        cpu.mem.withUnsafeMutableBufferPointer { mem in
            banks.withUnsafeMutableBufferPointer { stored in
                for page in 0 ..< 0xC0 {
                    let (read, write) = banks(of: page)
                    if read != auxInMemory[page] {
                        let a = page << 8, inMemory = mem.baseAddress! + a
                        (stored.baseAddress! + (read ? 0 : 0xC000) + a).update(from: inMemory, count: 0x100)
                        inMemory.update(from: stored.baseAddress! + (read ? 0xC000 : 0) + a, count: 0x100)
                        auxInMemory[page] = read
                    }
                    cpu.ioWritePages[page] = read != write
                }
            }
        }
    }

    /// The display switches as the screen shows them: with 80STORE on, page 1
    /// (PAGE2 picks a bank then).
    public var displayMode: VideoMode {
        var mode = video
        if iie.store80 { mode.page2 = false }
        return mode
    }

    /// Main memory (`aux` false) or aux memory below $C000 as it is: 48K.
    /// Aux is the //e's only (else empty).
    public func ram(aux: Bool = false) -> [UInt8] {
        guard isIIe else { return aux ? [] : Array(cpu.mem[0 ..< 0xC000]) }
        syncBanks()
        return Array(banks[aux ? 0xC000 ..< 0x18000 : 0 ..< 0xC000])
    }

    /// Puts `bytes` in main memory from `address` (cut off at $C000),
    /// whichever bank the CPU sees there.
    public func writeMain(_ bytes: some Collection<UInt8>, at address: Int) {
        for (i, byte) in zip(address ..< 0xC000, bytes) {
            if isIIe && auxInMemory[i >> 8] { banks[i] = byte } else { cpu.mem[i] = byte }
        }
        if keepsShadow { syncShadow() }
    }

    /// `cpu.mem` holds aux memory's `page` (main memory's is in `banks`).
    @inline(__always) func isAuxInMemory(_ page: Int) -> Bool { auxInMemory[page] }

    /// Main memory's `page` where `cpu.mem` holds aux memory's.
    func mainBankPage(_ page: Int) -> ArraySlice<UInt8> { banks[page << 8 ..< page << 8 + 0x100] }

    /// `banks` up to date: the pages `cpu.mem` holds copied there (they
    /// stay in `cpu.mem`).
    private func syncBanks() {
        cpu.mem.withUnsafeBufferPointer { mem in
            banks.withUnsafeMutableBufferPointer { stored in
                for page in 0 ..< 0xC0 {
                    let a = page << 8
                    (stored.baseAddress! + (auxInMemory[page] ? 0xC000 : 0) + a).update(from: mem.baseAddress! + a, count: 0x100)
                }
            }
        }
    }

    /// Runs `body` on main and aux memory as they are (aux nil but on the
    /// //e), for the display.
    func withMemory<R>(_ body: (_ main: UnsafePointer<UInt8>, _ aux: UnsafePointer<UInt8>?) -> R) -> R {
        guard isIIe else { return cpu.mem.withUnsafeBufferPointer { body($0.baseAddress!, nil) } }
        syncBanks()
        return banks.withUnsafeBufferPointer { body($0.baseAddress!, $0.baseAddress! + 0xC000) }
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
        case 4: s.altZP = on
        case 5: s.slotC3ROM = on
        case 6: video.col80 = on
        default: video.altCharset = on
        }
        if s != iie { setIIeSwitches(s) }
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
        default: on = video.col80
        }
        return (on ? 0x80 : 0) | keyboard.latch & 0x7F
    }

    /// $C000-$C0FF: a read, or a write of `value`; both throw the switches.
    private func io(_ a: UInt16, write: Bool, value: UInt8) -> UInt8 {
        if let ioHook, let byte = ioHook(a, write, value) { return byte }
        let low = Int(a & 0xFF)
        switch low >> 4 {
        case 0x0:
            if write && isIIe { setIIeSwitch(low) }
            let latch = readKeyboard(at: cpu.cycles)
            // BASIC waits for a key: the slot scan is over (a read: the //e's
            // reset writes here, to its memory switches, before the scan)
            if !write, latch & 0x80 == 0 { diskROMHidden = false }
            return latch
        case 0x1:
            if isIIe && low != 0x10 { return write ? 0 : iieStatus(low & 0xF) }
            return clearKeyStrobe(at: cpu.cycles)
        case 0x3:
            speakerClicks += 1
            clicks?.append(cpu.cycles)
        case 0x5:
            let was = video
            video.set(low & 0xF)
            // the //e's 80STORE: PAGE2 (and HIRES) pick the bank of the text and hi-res page 1
            if iie.store80, video.page2 != was.page2 || video.hires != was.hires { mapAuxMemory() }
        case 0x6:
            switch low & 7 {
            case 1 ... 3: return gamePort.button((low & 7) - 1) ? 0x80 : 0
            case 4 ... 7: return paddleRunning((low & 7) - 4, at: cpu.cycles) ? 0x80 : 0
            default: return 0                   // cassette in
            }
        case 0x7:
            if isIIe && low == 0x7F && !write { return video.dhires ? 0x80 : 0 }   // RDDHIRES
            triggerPaddles(at: cpu.cycles)
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

    /// The 16K of the language card: $D000 bank 1, $D000 bank 2, $E000-$FFFF
    /// (the //e's main bank, whatever ALTZP picks).
    public var languageCardRAM: [UInt8] {
        if iie.altZP { return otherLanguageCardRAM }
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

    /// The //e's switches that are on: "RAMWRT 80STORE INTCXROM".
    var iieState: String {
        let on = [("80STORE", iie.store80), ("RAMRD", iie.ramRead), ("RAMWRT", iie.ramWrite), ("ALTZP", iie.altZP),
                  ("INTCXROM", iie.intCXROM), ("SLOTC3ROM", iie.slotC3ROM), ("PAGE2", video.page2),
                  ("80COL", video.col80), ("DHIRES", video.dhires), ("ALTCHARSET", video.altCharset)]
        return on.filter(\.1).map(\.0).joined(separator: " ")
    }

    /// It has its model's ROM (else it's a host's machine, see above).
    public var hasROM: Bool { rom != nil }

    // MARK: the host's

    /// Puts `memory` in main RAM ($0000-$BFFF; a 64K image's rest is left
    /// out) and `languageCard` (16K, as `languageCardRAM`) in the language
    /// card's RAM (the //e's main bank); the switches stay.
    public func load(memory: [UInt8], languageCard ram: [UInt8]) {
        precondition(memory.count >= 0xC000 && ram.count == 0x4000, "48K (or 64K) of main RAM and the card's 16K")
        writeMain(memory[0 ..< 0xC000], at: 0)
        if iie.altZP {
            otherLanguageCardRAM = ram
        } else {
            unmapLanguageCard()
            languageCard.ram = ram
            mapLanguageCard()
        }
    }

    /// Puts `card` in `slot` (1-7, not the Disk II's 6), or takes the card
    /// there out (nil): its ROM page is read at $Cn00-$CnFF, its switches
    /// are $C080 + slot × 16 on.
    public func insert(_ card: Apple2Card?, slot: Int) {
        precondition((1 ... 7).contains(slot) && slot != Apple2Machine.diskSlot && slot != MouseCard.slot,
                     "slots 1-7 but the Disk II's and the mouse card's")
        cards[slot] = card
        putROMPage(slot)
    }

    /// A card is in `slot`: one inserted, or the mouse card while enabled.
    private func hasCard(_ slot: Int) -> Bool {
        cards[slot] != nil || slot == MouseCard.slot && mouseEnabled
    }

    /// A card's ROM page lies in `cpu.mem` at $Cn00 (the CPU reads it
    /// through `read`, a host's code there as on the Apple): an empty slot's
    /// is zeros.
    private func putROMPage(_ slot: Int) {
        let page = 0xC000 | slot << 8
        let bytes = slot == MouseCard.slot && mouseEnabled ? MouseCard.romPage : cards[slot]?.romPage ?? []
        precondition(bytes.isEmpty || bytes.count == 0x100, "a card's ROM page is 256 bytes")
        cpu.mem.replaceSubrange(page ..< page + 0x100, with: bytes.isEmpty ? [UInt8](repeating: 0, count: 0x100) : bytes)
    }

    /// An independent machine in the same state: memory, the switches, the
    /// devices, the drives and their disks, the CPU's registers and cycles,
    /// the hooks and their switches, the shadow of the hi-res pages.  The
    /// cards are the same (a card keeps its own state); the host's `ioHook`,
    /// `onTrap`, `onShadowWrite` and `host`, and the CPU's traps it set
    /// itself and its watches, aren't copied.
    public func copy() -> Apple2Machine {
        let c = Apple2Machine(model: model, rom: rom, diskROM: diskROM)
        c.cpu.mem = cpu.mem
        c.cpu.ioPages = cpu.ioPages
        c.cpu.ioWritePages = cpu.ioWritePages
        c.banks = banks
        c.auxInMemory = auxInMemory
        c.otherLanguageCardRAM = otherLanguageCardRAM
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
        c.gamePort = gamePort
        c.mouseEnabled = mouseEnabled           // first: putting the card in resets it
        c.mouse = mouse
        c.hooks = hooks
        c.hooks.endTraces()                     // a copy made inside a native's trace isn't in it
        for address in hooks.active.keys { c.refreshTrap(address) }
        c.verticalBlanks = verticalBlanks
        c.speakerClicks = speakerClicks
        c.clicks = clicks
        c.diskROMHidden = diskROMHidden
        c.keepsShadow = keepsShadow
        c.shadowBytes = shadowBytes
        c.onShadowWrite = nil                   // the host's
        return c
    }

    /// The machine as it is, to put back later (`restore`), in this run of
    /// the app or a later one (`State`).
    public var state: State {
        var keys = keyboard
        keys.releaseAll()
        return State(model: model.rawValue, a: cpu.a, x: cpu.x, y: cpu.y, sp: cpu.sp, p: cpu.p, pc: cpu.pc,
                     cycles: cpu.cycles, stopsAtBRK: cpu.stopsAtBRK, memory: Data(cpu.mem),
                     ioPages: cpu.ioPages, ioWritePages: cpu.ioWritePages, banks: Data(banks),
                     auxInMemory: auxInMemory, otherLanguageCardRAM: Data(otherLanguageCardRAM),
                     languageCard: languageCard, mappedBank2: mappedBank2, iie: iie, video: video,
                     diskROMHidden: diskROMHidden, disk: disk.state, keyboard: keys, typeAhead: Data(typeAhead),
                     nextTypedKey: nextTypedKey, gamePort: gamePort, mouseEnabled: mouseEnabled, mouse: mouse,
                     verticalBlanks: verticalBlanks, speakerClicks: speakerClicks)
    }

    /// Puts the machine in `state`, one of a machine of this model; throws
    /// (`State.Problem`), the machine as it was, for another version, model,
    /// or a state that doesn't add up.  The host's cards, hooks and traps
    /// stay as they are; `clicks` starts again (empty, if it was there); the
    /// shadow (not in a state) starts again as a copy of the pages.
    public func restore(_ state: State) throws {
        guard state.version == State.currentVersion else { throw State.Problem.otherVersion(state.version) }
        guard state.model == model.rawValue else { throw State.Problem.otherModel(state.model) }
        guard state.memory.count == cpu.mem.count, state.banks.count == banks.count,
              state.ioPages.count == cpu.ioPages.count, state.ioWritePages.count == cpu.ioWritePages.count,
              state.auxInMemory.count == auxInMemory.count, state.otherLanguageCardRAM.count == 0x4000,
              state.languageCard.ram.count == 0x4000, state.languageCard.ramOnly == (rom == nil),
              state.disk.isValid
        else { throw State.Problem.damaged }
        mouseEnabled = state.mouseEnabled       // first: putting the card in resets it
        cpu.mem = [UInt8](state.memory)
        for slot in 1 ... 7 where hasCard(slot) { putROMPage(slot) }     // this machine's cards
        cpu.ioPages = state.ioPages
        cpu.ioWritePages = state.ioWritePages
        (cpu.a, cpu.x, cpu.y, cpu.sp, cpu.p, cpu.pc) = (state.a, state.x, state.y, state.sp, state.p, state.pc)
        cpu.cycles = state.cycles
        cpu.stopsAtBRK = state.stopsAtBRK
        banks = [UInt8](state.banks)
        auxInMemory = state.auxInMemory
        otherLanguageCardRAM = [UInt8](state.otherLanguageCardRAM)
        languageCard = state.languageCard
        mappedBank2 = state.mappedBank2
        iie = state.iie
        video = state.video
        diskROMHidden = state.diskROMHidden
        disk.restore(state.disk)
        keyboard = state.keyboard
        typeAhead = [UInt8](state.typeAhead)
        nextTypedKey = state.nextTypedKey
        gamePort = state.gamePort
        mouse = state.mouse
        verticalBlanks = state.verticalBlanks
        speakerClicks = state.speakerClicks
        if clicks != nil { clicks = [] }
        if keepsShadow { syncShadow() }         // not in the state: the pages as they are
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

    /// Fills text page 1 ($0400-$07FF, main memory) with spaces.
    public func cls() {
        writeMain(repeatElement(0xA0, count: 0x400), at: 0x400)
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
        writeMain(bytes.prefix(count), at: Screen.textAddress(row: y, page2: false) + column)
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

/// The display switches $C050-$C057 (and the //e's ALTCHARSET, 80COL and
/// DHIRES).
public nonisolated struct VideoMode: Equatable, Sendable, Codable, CustomStringConvertible {
    public var text = true
    public var mixed = false
    /// PAGE2.  With the //e's 80STORE on it picks the bank of page 1 and page
    /// 1 is shown (`Apple2Machine.displayMode`).
    public var page2 = false
    public var hires = false
    /// The //e's second character set: inverse lower case for flashing.
    public var altCharset = false
    /// The //e's 80 columns ($C00D): 80-column text, and with `dhires` double
    /// hi-res or double lo-res.
    public var col80 = false
    /// The //e's DHIRES (annunciator 3 off, $C05E; on $C05F).
    public var dhires = false
    /// How an RGB card (the Video-7 kind: Apple's Extended 80-Column
    /// Text/AppleColor card, Le Chat Mauve) shows double hi-res on an RGB
    /// monitor (`Screen.Style.filled`).
    public var rgb = RGBMode.color
    /// The RGB card's two flags, clocked in by `set`.
    private var rgbFlags = 0, an3Off = false

    /// An RGB card's double hi-res modes.  A program picks one turning
    /// annunciator 3 off then on ($C05E, $C05F) twice, each time with 80COL
    /// off for a 1, on for a 0: 00 colour, 11 monochrome, 10 mixed (01, 160
    /// pixels a line on some cards, shows as colour).
    public enum RGBMode: Sendable, Codable {
        /// 140 pixels a line of 4 dots each.
        case color
        /// The 560 dots in black and white.
        case monochrome
        /// A byte with bit 7 set in colour, else its dots in black and white.
        case mixed
    }

    /// What the screen shows: "Hi-res mixed", "80-column text", "Double hi-res".
    public var description: String {
        let graphics = (col80 && dhires ? "Double " : "") + (hires ? "hi-res" : "lo-res")
        let name = text ? (col80 ? "80-column text" : "Text") : graphics.prefix(1).uppercased() + graphics.dropFirst()
        return name + (mixed && !text ? " mixed" : "")
    }

    /// The RGB card back to colour, as RESET leaves it.
    mutating func resetRGB() { (rgb, rgbFlags, an3Off) = (.color, 0, false) }

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
        case 0xE: dhires = true
        case 0xF:
            dhires = false
            if an3Off {                         // the RGB card clocks in !80COL
                rgbFlags = (rgbFlags << 1 & 3) | (col80 ? 0 : 1)
                rgb = [.color, .color, .mixed, .monochrome][rgbFlags]
            }
        default: break                          // the other annunciators
        }
        if n & 0xE == 0xE { an3Off = n == 0xE }
    }
}

/// The //e's switches for memory and ROM ($C000-$C00B written, read at
/// $C013-$C018): which bank the CPU reads and writes (`Apple2Machine.banks(of:)`),
/// which ROM is at $C100-$CFFF.
nonisolated struct IIeSwitches: Equatable, Codable {
    var store80 = false, ramRead = false, ramWrite = false, altZP = false
    var intCXROM = false, slotC3ROM = false
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

/// For a saved state (`Apple2Machine.State`): the RAM as `Data`.
extension LanguageCard: Codable {
    private enum CodingKeys: String, CodingKey {
        case ram, ramOnly, readsRAM, writesRAM, bank2, preWrite
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ram = [UInt8](try c.decode(Data.self, forKey: .ram))
        ramOnly = try c.decode(Bool.self, forKey: .ramOnly)
        readsRAM = try c.decode(Bool.self, forKey: .readsRAM)
        writesRAM = try c.decode(Bool.self, forKey: .writesRAM)
        bank2 = try c.decode(Bool.self, forKey: .bank2)
        preWrite = try c.decode(Bool.self, forKey: .preWrite)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Data(ram), forKey: .ram)
        try c.encode(ramOnly, forKey: .ramOnly)
        try c.encode(readsRAM, forKey: .readsRAM)
        try c.encode(writesRAM, forKey: .writesRAM)
        try c.encode(bank2, forKey: .bank2)
        try c.encode(preWrite, forKey: .preWrite)
    }
}
