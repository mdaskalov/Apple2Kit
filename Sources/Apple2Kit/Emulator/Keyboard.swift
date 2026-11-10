import Foundation

/// The keyboard as the hardware has it: the latch the code reads at $C000
/// (the last key, bit 7 – the strobe – set until $C010 clears it), the keys
/// held down, and the //e's auto-repeat (Docs/Hardware.md "Keyboard").
///
/// The host tells it keys going down and up (`keyDown`, `keyUp`) and drops
/// its own repeats: a held key repeats here, as on the //e – its keyboard
/// encoder types the newest key held again after `repeatDelay`, then every
/// `repeatPeriod`.  The ][ and ][+ don't repeat (their REPT key isn't here).
/// The repeat is worked out when the latch is read (`update`), at the cycle
/// of the read, so it is the same however the CPU is run.
public nonisolated struct Keyboard: Sendable {
    /// The //e's auto-repeat: after about half a second held, about 15 a second.
    public static let repeatDelay = UInt64(Apple2Machine.clock / 2)
    public static let repeatPeriod = UInt64(Apple2Machine.clock / 15)

    /// $C000: the last key typed, bit 7 set until $C010 clears it.
    public internal(set) var latch: UInt8 = 0
    /// The keys down, oldest first: the host's key (its own number) and
    /// the code it typed.
    private var held: [Key] = []
    /// When the newest key held types again; nil: it doesn't.
    private var nextRepeat: UInt64?
    /// It repeats (the //e).
    let repeats: Bool

    private struct Key: Sendable {
        let id: Int
        let ascii: UInt8
    }

    init(repeats: Bool) {
        self.repeats = repeats
    }

    /// A key is down: the //e's any-key-down ($C010 bit 7).
    public var anyKeyDown: Bool { !held.isEmpty }

    /// A key typed: `ascii` (0-127) in the latch, the strobe set.
    mutating func press(_ ascii: UInt8) {
        latch = ascii | 0x80
    }

    /// Key `id` went down at `cycle`, typing `ascii`; it repeats while it is
    /// the newest key held.
    mutating func keyDown(_ ascii: UInt8, id: Int, at cycle: UInt64) {
        held.removeAll { $0.id == id }
        held.append(Key(id: id, ascii: ascii & 0x7F))
        press(ascii)
        nextRepeat = repeats ? cycle + Keyboard.repeatDelay : nil
    }

    /// Key `id` went up: the repeat stops if it was the newest key held.
    mutating func keyUp(id: Int) {
        if held.last?.id == id { nextRepeat = nil }
        held.removeAll { $0.id == id }
    }

    /// Every key up (the host lost the keyboard).
    mutating func releaseAll() {
        held = []
        nextRepeat = nil
    }

    /// The latch at `cycle`: the newest key held typed again if it has
    /// repeated since the last read.
    mutating func update(at cycle: UInt64) {
        guard let next = nextRepeat, cycle >= next, let key = held.last else { return }
        latch = key.ascii | 0x80
        nextRepeat = next + ((cycle - next) / Keyboard.repeatPeriod + 1) * Keyboard.repeatPeriod
    }
}
