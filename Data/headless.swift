// Runs the emulator core (Sources/Apple2Kit/Emulator) without an app, as fast as it
// goes, following the command line as a script.  Build and run with
// headless.sh; Data/README.md has the actions and examples.
import CoreGraphics
import Foundation
import ImageIO
import MOS6502

@main
struct Headless {
    static let usage = """
    usage: headless.sh [--roms DIR] [--model plus|ii|e] ACTION...
      --roms DIR                   the ROMs (default $APPLE2_ROMS, else ../roms)
      --disk PATH / --disk2 PATH   insert a disk image in drive 1 / 2
      --eject / --eject2           take it out
      --power                      power cycle (the ][+ boots drive 1)
      --basic                      power cycle into BASIC, disks or not
      --reset                      the RESET key
      --run SECONDS                run the CPU that long (emulated time)
      --until TEXT [SECONDS]       run until TEXT is on the text screen (at most 30 s)
      --type TEXT                  type TEXT (\\n: RETURN) and run until it is taken
      --screen                     print the text screen
      --status                     print CPU, switches, drives
      --style color|filled|mono    how --png colours the screen (default color)
      --png PATH                   write the display as a PNG (560 x 384)
      --wav PATH                   write the speaker since the start (or the last --wav) as a WAV
      --dump PATH                  write the 64K memory (and PATH.lc: the language card's 16K)
      --save-disk PATH             write drive 1's image with what was written to it
      --nib PATH                   write drive 1's nibble tracks as a .nib
    The machine powers on at the first action; the screen is printed at the end.
    """

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { print(usage); exit(2) }
        var romDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["APPLE2_ROMS"] ?? "../roms")
        var model = Apple2.Model.apple2Plus
        while let first = args.first, first == "--roms" || first == "--model" {
            args.removeFirst()
            let value = args.isEmpty ? "" : args.removeFirst()
            if first == "--roms" { romDir = URL(fileURLWithPath: value) }
            else if value == "ii" { model = .apple2 }
            else if value == "e" { model = .apple2e }
            else if value != "plus" { fail("--model plus|ii|e") }
        }
        let machine: Apple2
        do { machine = try ROMs.machine(model, from: romDir) } catch { fail("\(error.localizedDescription)") }
        machine.clicks = []
        var style = Screen.Style.color
        var speaker = SpeakerStream()
        let start = Date()
        var emulated = 0.0
        func run(_ seconds: Double, until done: () -> Bool = { false }) {
            let slice = Apple2.cyclesPerFrame
            var left = Int(seconds * Apple2.clock)
            while left > 0, !done() {
                do { try machine.run(cycles: min(slice, left)) } catch {
                    print("CPU stopped: \(error) at $\(hex(machine.cpu.pc, 4))")
                    printStatus(machine)
                    exit(1)
                }
                left -= slice
                emulated += Double(slice) / Apple2.clock
            }
        }
        func disk(_ path: String) -> DiskImage {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                return try DiskImage(name: (path as NSString).lastPathComponent, data: [UInt8](data))
            } catch { fail("\(path): \(error.localizedDescription)") }
        }

        while !args.isEmpty {
            let action = args.removeFirst()
            func value() -> String {
                guard !args.isEmpty else { fail("\(action) needs a value") }
                return args.removeFirst()
            }
            switch action {
            case "--disk":
                let image = disk(value())
                print("drive 1: \(image.name) (\(image.format.rawValue))")
                machine.disk.insert(image, drive: 0)
            case "--disk2":
                let image = disk(value())
                print("drive 2: \(image.name) (\(image.format.rawValue))")
                machine.disk.insert(image, drive: 1)
            case "--eject": machine.disk.eject(drive: 0)
            case "--eject2": machine.disk.eject(drive: 1)
            case "--power": machine.powerOn()
            case "--basic": machine.startBASIC()
            case "--reset": machine.reset()
            case "--run": run(Double(value()) ?? 1)
            case "--until":
                let text = value()
                var limit = 30.0
                if let s = args.first.flatMap(Double.init) { limit = s; args.removeFirst() }
                let before = emulated
                run(limit) { machine.screenText().contains(text) }
                let found = machine.screenText().contains(text)
                print(found ? "found \"\(text)\" after \(String(format: "%.2f", emulated - before)) s"
                            : "\"\(text)\" not on screen after \(limit) s")
            case "--type":
                machine.type(value().replacingOccurrences(of: "\\n", with: "\n"))
                run(60) { !machine.isTyping }
                run(0.1)
            case "--screen": printScreen(machine)
            case "--status": printStatus(machine)
            case "--style":
                switch value() {
                case "color": style = .color
                case "filled": style = .filled
                case "mono": style = .monochrome
                default: fail("--style color|filled|mono")
                }
            case "--png": writePNG(machine, style: style, to: value())
            case "--wav":
                let path = value()
                let clicks = machine.takeClicks()
                let samples = speaker.samples(clicks, upTo: machine.cpu.cycles, quiet: true)
                writeWAV(samples, to: path)
                print("speaker -> \(path) (\(clicks.count) clicks, \(String(format: "%.2f", Double(samples.count) / Double(SpeakerRenderer.sampleRate))) s)")
            case "--dump":
                let path = value()
                try? Data(machine.cpu.mem).write(to: URL(fileURLWithPath: path))
                try? Data(machine.languageCardRAM).write(to: URL(fileURLWithPath: path + ".lc"))
                print("memory -> \(path), \(path).lc")
            case "--save-disk":
                let path = value()
                guard var image = machine.disk.eject(drive: 0) else { fail("no disk in drive 1") }
                let written = image.dirtyTracks.sorted()
                try? Data(image.fileData()).write(to: URL(fileURLWithPath: path))
                machine.disk.insert(image, drive: 0)
                print("drive 1 -> \(path) (tracks written: \(written))")
            case "--nib":
                let path = value()
                guard let image = machine.disk.drives[0].image else { fail("no disk in drive 1") }
                try? Data(image.nibbles.flatMap { $0 }).write(to: URL(fileURLWithPath: path))
                print("drive 1 nibbles -> \(path)")
            default:
                fail("unknown action \(action)\n\(usage)")
            }
        }
        printScreen(machine)
        let wall = Date().timeIntervalSince(start)
        print(String(format: "%.1f s emulated in %.2f s (%.0f×)", emulated, wall, emulated / max(wall, 0.001)))
    }

    static func printScreen(_ m: Apple2) {
        let line = "+" + String(repeating: "-", count: 40) + "+"
        print(line)
        for row in m.screenText().split(separator: "\n", omittingEmptySubsequences: false) { print("|\(row)|") }
        print(line)
    }

    static func printStatus(_ m: Apple2) {
        let c = m.cpu, v = m.video
        print("PC=\(hex(c.pc, 4)) A=\(hex(c.a)) X=\(hex(c.x)) Y=\(hex(c.y)) SP=\(hex(c.sp)) P=\(hex(c.p)) cycles=\(c.cycles)")
        print("video: \(v.text ? "text" : v.hires ? "hires" : "lores")\(v.mixed ? " mixed" : "") page \(v.page2 ? 2 : 1); \(m.languageCardState); speaker clicks \(m.speakerClicks)")
        for (i, d) in m.disk.drives.enumerated() {
            print("drive \(i + 1): \(d.image?.name ?? "empty") track \(d.track) (half \(d.halfTrack))\(m.disk.selected == i && m.disk.motorOn(at: c.cycles) ? " motor on" : "")")
        }
    }

    static func writePNG(_ m: Apple2, style: Screen.Style, to path: String) {
        guard let image = m.screenImage(style: style, rowsTwice: true),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { fail("can't write \(path)") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("screen -> \(path)")
    }

    /// Mono 16-bit PCM at `SpeakerRenderer.sampleRate`.
    static func writeWAV(_ samples: [Float], to path: String) {
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(SpeakerRenderer.sampleRate), bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); le(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(rate); le(rate * 2); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(bytes)
        for s in samples { le(Int16(max(-1, min(1, s)) * 32767)) }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail("can't write \(path)") }
    }

    static func hex<T: BinaryInteger>(_ v: T, _ digits: Int = 2) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(2)
    }
}
