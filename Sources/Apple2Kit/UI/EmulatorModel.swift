import CoreGraphics
import Foundation
import MOS6502
import Observation
#if !os(watchOS)
import QuartzCore
#endif
import UniformTypeIdentifiers

/// The emulator as an app runs it: the machine, run with the display's
/// frames at the Apple's speed (faster while a disk turns, `fastDisk`), its
/// speaker, the disks in and out, binaries loaded into memory, the keyboard,
/// and a status of it all.  Show it with `Apple2View`, which runs it.
@Observable
public final class EmulatorModel {
    /// What a status bar shows of a drive.
    public struct DriveStatus: Equatable, Sendable {
        public var name: String?
        public var track = 0
        public var spinning = false
        public var modified = false
        public var format = ""
    }

    public private(set) var machine: Apple2
    /// The machine; another one restarts with the same disks.
    public var model: Apple2.Model {
        didSet { if model != oldValue { switchModel() } }
    }
    /// The speaker plays (else it is muted).  Either way what is queued goes:
    /// switched on, the next sound starts afresh.
    public var sound = true {
        didSet { if sound != oldValue { soundPlayer.stop() } }
    }
    /// Run as fast as it goes while a disk drive's motor is on.
    public var fastDisk = true
    public private(set) var paused = false
    /// Why the machine stopped, or a file that couldn't be opened.
    public var message: String?

    // status, refreshed a few times a second
    public private(set) var drives = [DriveStatus(), DriveStatus()]
    public private(set) var registers = ""
    /// MHz, measured.
    public private(set) var speed = 0.0
    public private(set) var videoMode = ""

    @ObservationIgnored private var lastFrame: CFTimeInterval?
    /// Cycles owed to the clock, fractions included.
    @ObservationIgnored private var owed = 0.0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var speedSample: (time: CFTimeInterval, cycles: UInt64)?
    @ObservationIgnored private let soundPlayer = SoundPlayer()

    /// The disk image files it takes.
    public static let diskTypes = ["dsk", "do", "po", "nib"].compactMap { UTType(filenameExtension: $0) }

    /// Where the ROMs are (`ROMs`): nil, the app's bundle (`roms/` in its
    /// resources, or the resources themselves).
    public let romDirectory: URL?

    /// A machine of `model`, powered on: the ][+ starts Applesoft (there is
    /// no disk yet).  The ROMs come from `romDirectory`, nil: the app's
    /// bundle; one missing is a programming error (`fatalError`).
    public init(model: Apple2.Model = .apple2Plus, romDirectory: URL? = nil) {
        self.model = model
        self.romDirectory = romDirectory
        do {
            machine = try ROMs.machine(model, from: romDirectory)
            machine.clicks = []
        } catch {
            fatalError("\(error.localizedDescription)")
        }
    }

    // MARK: running

    /// Runs the machine up to the display frame at `time`, plays what its
    /// speaker did, and returns its screen in `style`.  At most a tenth of a
    /// second is caught up; with `fastDisk` it may run on ahead (`runAhead`).
    func frame(at time: CFTimeInterval, style: Screen.Style) -> CGImage? {
        defer { lastFrame = time }
        if !paused, let last = lastFrame {
            owed += min(max(time - last, 0), 0.1) * Apple2.clock
            let start = machine.cpu.cycles
            run(max(0, Int(owed)))
            // what ran, the last instruction's overrun too: else the machine,
            // and its sound, gain on the clock
            owed -= Double(machine.cpu.cycles &- start)
            soundPlayer.play(machine.takeClicks(), upTo: machine.cpu.cycles, quiet: paused, muted: !sound)
            if fastDisk { runAhead() }
        }
        frameCount += 1
        if frameCount % 6 == 0 { refreshStatus(at: time) }
        return machine.screenImage(style: style)
    }

    /// *Fast Disk*: while a drive's motor turns, runs on ahead of the clock
    /// for up to 12 ms of the Mac's time – but not while the speaker sounds
    /// (unless muted): its sound keeps the clock's time.  A click stops it
    /// there, and the next frame plays it.  (Sound made while running ahead
    /// would come too fast, chopped up, and late: queued ahead of what
    /// follows.)
    private func runAhead() {
        guard !paused, !(sound && soundPlayer.isSounding), machine.disk.motorOn(at: machine.cpu.cycles) else { return }
        let deadline = mediaTime() + 0.012
        while !paused, machine.disk.motorOn(at: machine.cpu.cycles), mediaTime() < deadline {
            if sound, machine.clicks?.isEmpty == false { return }
            run(Apple2.cyclesPerFrame)
        }
        if !sound { _ = machine.takeClicks() }
    }

    private func run(_ cycles: Int) {
        do {
            try machine.run(cycles: cycles)
        } catch {
            paused = true
            message = "The CPU stopped: \(error) at $\(hex(machine.cpu.pc, 4))."
            refreshStatus(at: mediaTime())
        }
    }

    private func refreshStatus(at time: CFTimeInterval) {
        let disk = machine.disk
        let spinning = disk.motorOn(at: machine.cpu.cycles)
        drives = disk.drives.enumerated().map { i, d in
            DriveStatus(name: d.image?.name, track: d.track, spinning: spinning && disk.selected == i,
                        modified: d.image?.isModified ?? false, format: d.image?.format.rawValue ?? "")
        }
        let c = machine.cpu
        registers = "PC \(hex(c.pc, 4))  A \(hex(c.a))  X \(hex(c.x))  Y \(hex(c.y))  SP \(hex(c.sp))  P \(flags(c.p))"
        let v = machine.video
        videoMode = v.text ? "Text" : (v.hires ? "Hi-res" : "Lo-res") + (v.mixed ? " mixed" : "")
        videoMode += v.page2 ? " · page 2" : ""
        if let sample = speedSample, time - sample.time >= 0.5 {
            speed = Double(c.cycles &- sample.cycles) / (time - sample.time) / 1_000_000
            speedSample = (time, c.cycles)
        } else if speedSample == nil {
            speedSample = (time, c.cycles)
        }
    }

    // MARK: the machine

    /// Power off and on: boots drive 1, or (][+) starts Applesoft.
    public func restart() {
        machine.powerOn()
        resume()
    }

    /// Power off and on into BASIC, with the disks where they are.
    public func startBASIC() {
        machine.startBASIC()
        resume()
    }

    /// The RESET key (Ctrl-RESET).
    public func reset() {
        machine.reset()
        resume()
    }

    public func togglePause() {
        if paused {
            resume()
        } else {
            paused = true
            soundPlayer.play(machine.takeClicks(), upTo: machine.cpu.cycles, quiet: true, muted: !sound)
            refreshStatus(at: mediaTime())
        }
    }

    private func resume() {
        soundPlayer.stop()
        _ = machine.takeClicks()
        paused = false
        message = nil
        lastFrame = nil
        speedSample = nil
    }

    /// One instruction, while paused.
    public func step() {
        guard paused else { return }
        do { try machine.cpu.step() } catch { message = "The CPU stopped: \(error)." }
        refreshStatus(at: mediaTime())
    }

    /// Another model: a new machine with the same disks, powered on.
    private func switchModel() {
        do {
            let new = try ROMs.machine(model, from: romDirectory)
            new.clicks = []
            for i in 0 ..< 2 {
                if let image = machine.disk.eject(drive: i) { new.disk.insert(image, drive: i) }
            }
            machine = new
            resume()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: keyboard and buttons

    /// A key pressed: its ASCII code (0-127).
    public func press(_ ascii: UInt8) {
        machine.press(ascii)
    }

    /// Push button `n` (0-2) down or up.
    public func setButton(_ n: Int, pressed: Bool) {
        machine.buttons[n] = pressed
    }

    /// Types `text` key by key, as fast as the program takes them.
    public func type(_ text: String) {
        machine.type(text)
    }

    /// The text screen as 24 lines of 40 characters.
    public var screenText: String { machine.screenText() }

    // MARK: disks

    /// Puts the image at `url` in drive `drive` (0 or 1); `boot`: and power
    /// cycles to boot it.
    public func insert(_ url: URL, drive: Int, boot: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            insert(try DiskImage(name: url.lastPathComponent, data: [UInt8](Data(contentsOf: url))),
                   drive: drive, boot: boot)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Puts `image` in drive `drive` (0 or 1); `boot`: and power cycles to
    /// boot it.
    public func insert(_ image: DiskImage, drive: Int, boot: Bool) {
        machine.disk.insert(image, drive: drive)
        if boot { restart() }
        refreshStatus(at: mediaTime())
    }

    public func eject(drive: Int) {
        machine.disk.eject(drive: drive)
        refreshStatus(at: mediaTime())
    }

    public func hasDisk(_ drive: Int) -> Bool { drives[drive].name != nil }

    /// Drive `drive`'s disk as a file in its own format, with what was
    /// written to it (from now on it counts as saved); nil: no disk.
    public func diskFileData(drive: Int) -> [UInt8]? {
        guard var image = machine.disk.drives[drive].image else { return nil }
        let data = image.fileData()
        machine.disk.drives[drive].image = image    // written tracks saved
        refreshStatus(at: mediaTime())
        return data
    }

    // MARK: binaries

    /// Loads the binary file at `url` (as `Data/dsk.py extract` writes one:
    /// the bytes alone) at `address`, or at the address its name carries
    /// (`NAME#06XXXX`, `loadAddress(in:)`), else $0800.  See `load(_:at:run:)`.
    public func load(_ url: URL, at address: UInt16? = nil, run: Bool = true) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let address = address ?? Self.loadAddress(in: url.lastPathComponent) ?? 0x0800
            load([UInt8](try Data(contentsOf: url)), at: address, run: run)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Puts `bytes` in memory at `address` (up to $BFFF) and, with `run`,
    /// starts them there as DOS's BRUN does: the machine as it is, the CPU
    /// jumping to `address`, with a return to the monitor ($FF69, the `*`
    /// prompt) on the stack for a program that ends in RTS.
    ///
    /// A machine that hasn't run yet first runs the ROM's start-up for half a
    /// second (without booting a disk): it sets up the screen and the I/O
    /// hooks a program may call (COUT…).
    public func load(_ bytes: [UInt8], at address: UInt16, run: Bool = true) {
        let startUp = Int(Apple2.clock / 2)
        if machine.cpu.cycles < UInt64(startUp) {
            machine.startBASIC()
            try? machine.run(cycles: startUp)
        }
        let start = Int(address)
        let count = min(bytes.count, max(0, 0xC000 - start))
        machine.cpu.mem.replaceSubrange(start ..< start + count, with: bytes.prefix(count))
        if run {
            resume()
            let monitor: UInt16 = 0xFF69 - 1        // RTS adds 1
            machine.cpu.push(UInt8(monitor >> 8))
            machine.cpu.push(UInt8(monitor & 0xFF))
            machine.cpu.pc = address
        }
        if count < bytes.count {
            message = "\(bytes.count - count) bytes past $BFFF were left out."
        }
        refreshStatus(at: mediaTime())
    }

    /// The load address in a file's name: `#06XXXX` (a binary file and its
    /// address, as CiderPress names them), e.g. `GAME#064000.bin`.
    public static func loadAddress(in name: String) -> UInt16? {
        guard let range = name.range(of: "#06[0-9A-Fa-f]{4}", options: .regularExpression) else { return nil }
        return UInt16(name[range].dropFirst(3), radix: 16)
    }

    // MARK: memory

    /// The 64K memory, and the language card's 16K ($D000 bank 1, $D000
    /// bank 2, $E000-$FFFF), for the tools in Data/ (dis6502.py, hexdump.py,
    /// hires.py).
    public var memoryDump: (memory: [UInt8], languageCard: [UInt8]) {
        (machine.cpu.mem, machine.languageCardRAM)
    }
}

/// `v` in hex, `digits` long.
/// Now, in the display links' time (`CACurrentMediaTime`; watchOS, without
/// QuartzCore: the same clock, the system's uptime).
func mediaTime() -> CFTimeInterval {
    #if !os(watchOS)
    CACurrentMediaTime()
    #else
    ProcessInfo.processInfo.systemUptime
    #endif
}

func hex<T: BinaryInteger>(_ v: T, _ digits: Int = 2) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, digits - s.count)) + s
}

/// The status flags as letters, set ones in capitals: NV-BDIZC.
private func flags(_ p: UInt8) -> String {
    String(zip("NV-BDIZC", (0 ..< 8).reversed()).map { letter, bit in
        p >> bit & 1 != 0 ? letter : Character(letter.lowercased())
    })
}
