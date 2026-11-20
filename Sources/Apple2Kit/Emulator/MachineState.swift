import Foundation

extension Apple2Machine {
    /// The machine's state, to keep beyond the app's run (`state`,
    /// `restore`; `Apple2.savedState()` has it as data): what `copy` copies
    /// but the host's – memory, the switches, the CPU's registers and
    /// cycles, the devices, the drives and their disks with what was written
    /// to them.  Not the cards, the hooks, `ioHook`, `onTrap`, `host`, the
    /// CPU's traps and watches; keys held are let go (their key-up would
    /// never come).
    public nonisolated struct State: Codable {
        /// The format's version: a state of another isn't restored.
        static let currentVersion = 1

        var version = State.currentVersion
        /// `Model`'s raw value.
        var model: String
        var a: UInt8, x: UInt8, y: UInt8, sp: UInt8, p: UInt8
        var pc: UInt16
        var cycles: UInt64
        var stopsAtBRK: Bool
        var memory: Data
        var ioPages: [Bool], ioWritePages: [Bool]
        var banks: Data
        var auxInMemory: [Bool]
        var otherLanguageCardRAM: Data
        var languageCard: LanguageCard
        var mappedBank2: Bool?
        var iie: IIeSwitches
        var video: VideoMode
        var diskROMHidden: Bool
        var disk: DiskII.State
        var keyboard: Keyboard
        var typeAhead: Data
        var nextTypedKey: UInt64
        var gamePort: GamePort
        var mouseEnabled: Bool
        var mouse: MouseCard
        var verticalBlanks: UInt64
        var speakerClicks: Int

        /// Why a state can't be restored.
        public enum Problem: LocalizedError {
            /// Saved in another version of the format.
            case otherVersion(Int)
            /// The state of another model (its name).
            case otherModel(String)
            /// Its memory, or a drive, doesn't add up.
            case damaged

            public var errorDescription: String? {
                switch self {
                case let .otherVersion(version): "The saved state is of another version (\(version))."
                case let .otherModel(name): "The saved state is of another machine (\(name))."
                case .damaged: "The saved state is damaged."
                }
            }
        }

        /// The model it was saved from.
        public var savedModel: Model? { Model(rawValue: model) }
    }
}
