import Foundation

/// The game I/O port: four paddle timers ($C064-$C067, started by $C070)
/// and three push buttons ($C061-$C063), with a two-axis joystick on
/// paddles 0 and 1 and buttons 0 and 1 (Docs/Hardware.md "Game port").
///
/// $C070 starts each paddle's timer (a 558) for a time in proportion to
/// its position, `cyclesPerStep` a step – AppleWin's 2816 cycles at 255,
/// from KEGS – and a paddle at 255 as at 287 (KEGS: a joystick all the way
/// over outlasts the count of a program that reads 0-255).  A timer still
/// running isn't restarted.  Nothing plugged in: its timer never runs out
/// (bit 7 stays set, PREAD reads 255), as on the Apple.
public nonisolated struct GamePort: Sendable {
    /// CPU cycles a paddle step of its timer takes.
    public static let cyclesPerStep = 2816.0 / 255.0

    /// The paddles' positions, 0-255; nil: nothing plugged in.  Paddles 0
    /// and 1 are the joystick's while one is plugged in.
    public var paddles: [UInt8?] = [nil, nil, nil, nil]
    /// The push buttons ($C061-$C063): the host's keys for them.
    public var buttons = [false, false, false]
    /// A joystick on paddles 0 (x) and 1 (y) and buttons 0 and 1; nil: none.
    public var joystick: Joystick?
    /// The cycle each paddle's timer runs to (`trigger`).
    private var ends: [UInt64] = [0, 0, 0, 0]

    /// A two-axis joystick with two buttons.
    public struct Joystick: Equatable, Sendable {
        /// The paddles: x 0 (left) to 255, y 0 (up) to 255.
        public var x: UInt8, y: UInt8
        public var buttons: [Bool]

        public init(x: UInt8, y: UInt8, buttons: [Bool] = [false, false]) {
            self.x = x
            self.y = y
            self.buttons = buttons
        }

        /// Let go: in the middle, the buttons up.
        public static let centre = Joystick(x: 128, y: 128)
    }

    /// Paddle `n`'s position (the joystick's for 0 and 1); nil: nothing plugged in.
    public func position(_ n: Int) -> UInt8? {
        if n < 2, let joystick { return n == 0 ? joystick.x : joystick.y }
        return paddles[n]
    }

    /// Button `n` is down: its key, or the joystick's.
    public func button(_ n: Int) -> Bool {
        buttons[n] || n < 2 && joystick?.buttons[n] == true
    }

    /// $C070 at `cycle`: each timer not running starts.
    mutating func trigger(at cycle: UInt64) {
        for n in 0 ..< 4 where cycle > ends[n] {
            guard let p = position(n) else { continue }
            ends[n] = cycle + UInt64(Double(p == 255 ? 287 : Int(p)) * GamePort.cyclesPerStep)
        }
    }

    /// Paddle `n`'s timer runs at `cycle` (its bit 7 at $C064 + n).
    public func running(_ n: Int, at cycle: UInt64) -> Bool {
        position(n) == nil || cycle <= ends[n]
    }
}
