import Foundation

/// The ROM images.  They are not part of the package: the app provides them
/// (README.md, Docs/Hardware.md).
///
/// | File | Size | |
/// |---|---|---|
/// | `apple2.rom` | 12K | $D000-$FFFF of the Apple ][ |
/// | `apple2plus.rom` | 12K | $D000-$FFFF of the Apple ][+ |
/// | `apple2e.rom` | 16K | $C000-$FFFF of the unenhanced Apple //e |
/// | `disk2.rom` | 256 bytes | the Disk II's boot ROM (P5, 16 sectors) |
///
/// Only the model's ROM and `disk2.rom` are needed.  Without a directory
/// they are looked up in the app's bundle: `roms/` in its resources, or
/// the resources themselves (an Xcode group such as `Resources/roms` is
/// copied there flat).
public nonisolated enum ROMs {
    public enum ROMError: LocalizedError {
        case missing(String, URL?)
        case size(String, Int)

        public var errorDescription: String? {
            switch self {
            case .missing(let name, let directory):
                "The ROM \(name).rom is missing (\(directory?.path ?? "the app's resources, or roms/ in them")). "
                    + "The app provides the ROMs: see Apple2Kit's README."
            case .size(let name, let size):
                "The ROM \(name).rom is \(size) bytes, not \(name == "disk2" ? "256" : name == "apple2e" ? "16K" : "12K")."
            }
        }
    }

    /// The Disk II's boot ROM.
    public static let diskROMName = "disk2"

    /// `name`.rom from `directory`, or from the app's bundle.
    public static func load(_ name: String, from directory: URL? = nil) throws -> [UInt8] {
        let url = directory.map { $0.appendingPathComponent(name + ".rom") }
            ?? Bundle.main.url(forResource: name, withExtension: "rom", subdirectory: "roms")
            ?? Bundle.main.url(forResource: name, withExtension: "rom")
        guard let url, let data = try? Data(contentsOf: url) else { throw ROMError.missing(name, directory) }
        return [UInt8](data)
    }

    /// A machine of `model` with its ROMs from `directory` (nil: the app's
    /// bundle, as `load`).
    public static func machine(_ model: Apple2.Model, from directory: URL? = nil) throws -> Apple2 {
        let rom = try load(model.romName, from: directory)
        guard rom.count == model.romSize else { throw ROMError.size(model.romName, rom.count) }
        let diskROM = try load(diskROMName, from: directory)
        guard diskROM.count == 0x100 else { throw ROMError.size(diskROMName, diskROM.count) }
        return Apple2(model: model, rom: rom, diskROM: diskROM)
    }
}
