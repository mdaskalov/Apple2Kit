import Foundation
import Testing
@testable import Apple2Kit

/// The ROMs (not in the package): `$APPLE2_ROMS`, else `roms/` in the
/// package's folder, as EmulatorTests has them.
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

/// A .dsk whose boot sector puts a "B" at the top left of the screen ($0400)
/// and loops.
private func bootDisk() throws -> DiskImage {
    var data = [UInt8](repeating: 0, count: DiskImage.sectorImageSize)
    let code: [UInt8] = [0x01, 0xA9, 0xC2, 0x8D, 0x00, 0x04, 0x4C, 0x06, 0x08]   // LDA #'B'; STA $0400; JMP *
    data.replaceSubrange(0 ..< code.count, with: code)
    return try DiskImage(name: "boot.dsk", data: data)
}

/// The machine's memory, registers and screen, to compare two machines.
@MainActor
private func snapshot(_ apple: Apple2) -> [String] {
    let m = apple.machine
    return [m.model.rawValue, "\(m.cpu.mem.hashValue)", "\(m.ram(aux: true).hashValue)",
            "\(m.languageCardRAM.hashValue)", apple.screenText,
            "\(m.cpu.a) \(m.cpu.x) \(m.cpu.y) \(m.cpu.sp) \(m.cpu.p) \(m.cpu.pc) \(m.cpu.cycles)",
            m.video.description, "\(m.disk.drives.map { $0.image?.name ?? "-" })"]
}

/// Start BASIC with a disk in drive 1: the prompt, the disk not booted (the
/// //e's reset writes its switches at $C000 before the slot scan).  The
/// disk boots afterwards (PR#6).
@MainActor
@Test(.enabled(if: hasROMs([.apple2Plus, .apple2e, .apple2eEnhanced]), "no ROMs"),
      arguments: [Apple2.Model.apple2Plus, .apple2e, .apple2eEnhanced])
func startBASICWithADisk(model: Apple2.Model) throws {
    let apple = Apple2(model: model, roms: .directory(romDirectory))
    apple.insert(try bootDisk(), drive: 0)
    apple.startBASIC()
    try apple.machine.run(cycles: Int(2 * Apple2.clock))
    #expect(apple.machine.peek(0x0400) != 0xC2)
    #expect(apple.screenText.split(separator: "\n").contains { $0.hasPrefix("]") })
    apple.type("PR#6\n")
    try apple.machine.run(cycles: Int(2 * Apple2.clock))
    #expect(apple.machine.peek(0x0400) == 0xC2)
}

/// A binary loaded into a machine that hasn't run, with a disk in drive 1:
/// the start-up before it doesn't boot the disk.
@MainActor
@Test(.enabled(if: hasROMs([.apple2e]), "no ROMs")) func loadWithADiskDoesntBootIt() throws {
    let apple = Apple2(model: .apple2e, roms: .directory(romDirectory))
    apple.insert(try bootDisk(), drive: 0)
    apple.load([0x4C, 0x00, 0x03], at: 0x0300)          // JMP *
    try apple.machine.run(cycles: Int(Apple2.clock))
    #expect(apple.machine.peek(0x0400) != 0xC2)
    #expect(apple.machine.cpu.pc == 0x0300)
}

/// A state restored – in a machine of another model too – runs on exactly
/// as the machine it was saved from: Applesoft running a program, the
/// keys still to type, a disk with a track written.
@MainActor
@Test(.enabled(if: hasROMs(), "no ROMs"), arguments: Apple2.Model.allCases)
func savedStateRunsOnTheSame(model: Apple2.Model) throws {
    let apple = Apple2(model: model, roms: .directory(romDirectory))
    var disk = try bootDisk()
    disk.write(0xAA, halfTrack: 6, position: 100)
    apple.insert(disk, drive: 0)
    apple.mouse = model.isIIe
    apple.startBASIC()
    try apple.machine.run(cycles: Int(Apple2.clock))
    if model == .apple2 { apple.press(0x02) }           // Ctrl-B: Integer BASIC
    try apple.machine.run(cycles: Int(Apple2.clock / 2))
    apple.type("10 X = X + 1\n20 GOTO 10\nRUN\n")
    try apple.machine.run(cycles: 20_000)               // part typed

    let data = try apple.savedState()
    let other = Apple2(model: model == .apple2Plus ? .apple2 : .apple2Plus, roms: .directory(romDirectory))
    try other.restore(data)
    #expect(other.model == model)
    #expect(other.mouse == model.isIIe)
    #expect(other.drives[0].name == "boot.dsk" && other.drives[0].modified)
    #expect(snapshot(other) == snapshot(apple))
    for _ in 0 ..< 3 {
        try apple.machine.run(cycles: Int(Apple2.clock / 2))
        try other.machine.run(cycles: Int(Apple2.clock / 2))
        #expect(snapshot(other) == snapshot(apple))
    }
    #expect(apple.screenText.contains("RUN"))
    #expect(apple.diskFileData(drive: 0) == other.diskFileData(drive: 0))
}

/// A .woz in a state: its bits, lengths and tracks as they were, what was
/// written saved the same.
@Test func wozImageInAState() throws {
    var image = try DiskImage(name: "test.woz", data: WOZTests.woz2())
    image.write(0xD5, halfTrack: 0, position: 3)
    image.setLength(10, halfTrack: 0, position: 3)
    let data = try PropertyListEncoder().encode(image)
    var back = try PropertyListDecoder().decode(DiskImage.self, from: data)
    #expect(back.isModified && back.format == .woz)
    for halfTrack in 0 ..< 80 {
        #expect(back.track(atHalfTrack: halfTrack) == image.track(atHalfTrack: halfTrack))
        #expect(back.lengths(atHalfTrack: halfTrack) == image.lengths(atHalfTrack: halfTrack))
    }
    #expect(back.fileData() == image.fileData())
}

/// Data that isn't a state, or a state of a version to come: refused, the
/// machine as it was.
@MainActor
@Test(.enabled(if: hasROMs([.apple2Plus]), "no ROMs")) func badStateIsRefused() throws {
    let apple = Apple2(roms: .directory(romDirectory))
    try apple.machine.run(cycles: Int(Apple2.clock))
    let before = snapshot(apple)
    #expect(throws: (any Error).self) { try apple.restore(Data("not a state".utf8)) }
    var state = apple.machine.state
    state.version += 1
    #expect(throws: Apple2Machine.State.Problem.self) { try apple.machine.restore(state) }
    state = apple.machine.state
    state.memory = Data(count: 100)
    #expect(throws: Apple2Machine.State.Problem.self) { try apple.machine.restore(state) }
    #expect(snapshot(apple) == before)
}
