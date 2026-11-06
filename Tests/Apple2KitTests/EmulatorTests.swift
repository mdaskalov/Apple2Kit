import Foundation
import Testing
@testable import Apple2Kit

/// The ROMs (not in the package): `$APPLE2_ROMS`, else `roms/` in the
/// package's folder (git-ignored).  The tests that need them are skipped
/// without them.
private let romDirectory: URL = {
    if let path = ProcessInfo.processInfo.environment["APPLE2_ROMS"] { return URL(fileURLWithPath: path) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../roms").standardizedFileURL
}()

private func hasROMs(_ models: [Apple2.Model] = Apple2.Model.allCases) -> Bool {
    (models.map(\.romName) + [ROMs.diskROMName]).allSatisfy {
        FileManager.default.fileExists(atPath: romDirectory.appendingPathComponent($0 + ".rom").path)
    }
}

/// Runs the machine `seconds` of its time, without a display.
@MainActor
private func run(_ emulator: EmulatorModel, _ seconds: Double) throws {
    try emulator.machine.run(cycles: Int(seconds * Apple2.clock))
}

@MainActor
@Test(.enabled(if: hasROMs([.apple2Plus]), "no ROMs")) func applesoftPrints() throws {
    let emulator = EmulatorModel(romDirectory: romDirectory)
    try run(emulator, 1)
    emulator.type("PRINT 2+2\n")
    try run(emulator, 1)
    #expect(emulator.screenText.split(separator: "\n").contains { $0.hasPrefix("4 ") })
}

/// A binary that prints "HI" through COUT ($FDED) and returns.
private let printHI: [UInt8] = [0xA9, 0xC8, 0x20, 0xED, 0xFD, 0xA9, 0xC9, 0x20, 0xED, 0xFD, 0x60]

@MainActor
@Test(.enabled(if: hasROMs(), "no ROMs"), arguments: Apple2.Model.allCases)
func loadAndRunBinary(model: Apple2.Model) throws {
    let emulator = EmulatorModel(model: model, romDirectory: romDirectory)
    emulator.load(printHI, at: 0x0300)
    #expect(emulator.machine.cpu.pc == 0x0300)
    #expect(emulator.machine.peek(0x0300) == 0xA9)
    try run(emulator, 1)
    // printed, then RTS to the monitor's prompt
    let lines = emulator.screenText.split(separator: "\n")
    #expect(emulator.screenText.contains("HI"))
    #expect(lines.contains { $0.hasPrefix("*") })
}

@MainActor
@Test(.enabled(if: hasROMs([.apple2e]), "no ROMs")) func iieLowerCase() throws {
    let emulator = EmulatorModel(model: .apple2e, romDirectory: romDirectory)
    try run(emulator, 1)
    #expect(emulator.screenText.contains("Apple ]["))
    emulator.type("print 6*7\n")
    try run(emulator, 1)
    #expect(emulator.screenText.contains("print 6*7"))
}

@Test func loadAddressFromName() {
    #expect(EmulatorModel.loadAddress(in: "GAME#064000.bin") == 0x4000)
    #expect(EmulatorModel.loadAddress(in: "GAME.bin") == nil)
}
