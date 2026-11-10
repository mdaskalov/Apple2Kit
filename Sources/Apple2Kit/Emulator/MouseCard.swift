import Foundation

/// An AppleMouse II card in slot 4, always in the machine, seen by the code
/// while `Apple2Machine.mouseEnabled` (else the slot is empty).  Like the
/// Disk II it is part of the machine; it could become a card of the slots.
///
/// The card's own ROM and microcontroller aren't here (AppleWin runs the
/// firmware, Apple's): its ROM page has what programs look for (the Pascal
/// firmware's bytes $Cn05 $38, $Cn07 $18, $Cn0B $01, the mouse's ID $Cn0C
/// $20 and $CnFB $D6), the firmware's table at $Cn12-$Cn19 (`Call`), and an
/// RTS at each routine, where the machine runs the routine (`run`) and
/// returns.  The routines answer as the firmware's do, through the slot's
/// screen holes (`Hole`), X = $Cn and Y = $n0 or not; a call takes no time
/// (Docs/Hardware.md "Mouse").
///
/// The status (READMOUSE): bit 7 the button down (or pressed since the
/// last read: a click between two reads isn't lost), bit 6 down at the last
/// read, bit 5 moved since the last read; bits 1-3 the interrupts SERVEMOUSE
/// found (movement, button, VBL).  The mode (SETMOUSE): bit 0 the mouse on,
/// bits 1-3 interrupts on movement, on the button and at each vertical
/// blank; the card holds the IRQ line (`irq`) until SERVEMOUSE takes the
/// interrupt.
public nonisolated struct MouseCard: Sendable {
    public static let slot = 4
    /// The card's ROM page, $C400.
    static let rom = 0xC000 | slot << 8

    /// The firmware's routines, by where their offset is in the ROM ($Cn12...).
    public enum Call: Int, CaseIterable, Sendable {
        case setMouse = 0x12, serveMouse, readMouse, clearMouse, posMouse, clampMouse, homeMouse, initMouse

        /// Where the routine is: $Cn80 on, an RTS each.
        public var entry: UInt16 { UInt16(MouseCard.rom + 0x80 + rawValue - Call.setMouse.rawValue) }
    }

    /// The screen holes of the card's slot (text page 1): the position
    /// (low, high), the status and the mode; and slot 0's, CLAMPMOUSE's bounds.
    public enum Hole {
        public static let xLow = 0x0478 + slot, yLow = 0x04F8 + slot, xHigh = 0x0578 + slot, yHigh = 0x05F8 + slot
        public static let status = 0x0778 + slot, mode = 0x07F8 + slot
        public static let lowLow = 0x0478, highLow = 0x04F8, lowHigh = 0x0578, highHigh = 0x05F8
    }

    /// The status and mode bits.
    public enum Bit {
        public static let down: UInt8 = 0x80, downBefore: UInt8 = 0x40, moved: UInt8 = 0x20
        public static let vblInterrupt: UInt8 = 0x08, buttonInterrupt: UInt8 = 0x04, moveInterrupt: UInt8 = 0x02
        public static let on: UInt8 = 0x01
    }

    static let romPage: [UInt8] = {
        var page = [UInt8](repeating: 0, count: 256)
        for (i, v) in [(0x05, 0x38), (0x07, 0x18), (0x0B, 0x01), (0x0C, 0x20), (0xFB, 0xD6)] as [(Int, UInt8)] {
            page[i] = v
        }
        for call in Call.allCases {
            page[call.rawValue] = UInt8(Int(call.entry) - rom)
            page[Int(call.entry) - rom] = 0x60
        }
        return page
    }()

    /// The position, in counts (y down), kept within `clamp`.
    public private(set) var x = 0, y = 0
    /// The bounds CLAMPMOUSE set: 0-1023 each way as the card starts.
    public private(set) var clamp = (x: 0 ... 1023, y: 0 ... 1023)
    public private(set) var mode: UInt8 = 0
    /// The button is down.
    public private(set) var button = false
    /// A program's own way with the button: bit 7 only at the first read
    /// after a press, held or not, and never bit 6 – one click is one press
    /// however long it is held.  Not the card's.
    public var reportsClickOnce = false
    /// It went down since the last read.
    private var pressed = false
    /// Bit 7 at the last read: bit 6 at the next.
    private var downAtRead = false
    /// The mouse moved since the last read.
    private var moved = false
    /// The interrupts waiting for SERVEMOUSE (status bits 1-3).
    private var pending: UInt8 = 0

    public init() {}

    /// The card holds the IRQ line.
    public var irq: Bool { pending != 0 }
    /// It interrupts at each vertical blank.
    var interruptsAtVBL: Bool { mode & Bit.vblInterrupt != 0 }

    /// The mouse moved by (dx, dy) counts, y down (while it's on).
    mutating func move(dx: Int, dy: Int) {
        guard mode & Bit.on != 0, dx != 0 || dy != 0 else { return }
        x = min(max(x + dx, clamp.x.lowerBound), clamp.x.upperBound)
        y = min(max(y + dy, clamp.y.lowerBound), clamp.y.upperBound)
        moved = true
        if mode & Bit.moveInterrupt != 0 { pending |= Bit.moveInterrupt }
    }

    /// The button pressed or let go.
    mutating func set(button down: Bool) {
        guard down != button else { return }
        if down { pressed = true }
        button = down
        if mode & (Bit.on | Bit.buttonInterrupt) == Bit.on | Bit.buttonInterrupt { pending |= Bit.buttonInterrupt }
    }

    /// A vertical blank began.
    mutating func verticalBlank() {
        if interruptsAtVBL { pending |= Bit.vblInterrupt }
    }

    /// Runs firmware routine `call` with A and the memory as the CPU has them;
    /// returns the carry: set where a call fails, else clear.
    mutating func run(_ call: Call, a: UInt8, mem: inout [UInt8]) -> Bool {
        switch call {
        case .setMouse:
            guard a <= 0x0F else { return true }
            mode = a
            mem[Hole.mode] = a
            if mode & Bit.vblInterrupt == 0 { pending &= ~Bit.vblInterrupt }
        case .serveMouse:
            guard pending != 0 else { return true }     // not the mouse's interrupt
            mem[Hole.status] = mem[Hole.status] & ~0x0E | pending
            pending = 0
        case .readMouse:
            let down = reportsClickOnce ? pressed : button || pressed
            var status: UInt8 = down ? Bit.down : 0
            if downAtRead && !reportsClickOnce { status |= Bit.downBefore }
            if moved { status |= Bit.moved }
            (downAtRead, pressed, moved) = (down, false, false)
            mem[Hole.status] = status
            putPosition(&mem)
        case .clearMouse:
            (x, y) = (0, 0)
            putPosition(&mem)
        case .posMouse:
            x = position(mem, Hole.xLow, Hole.xHigh)
            y = position(mem, Hole.yLow, Hole.yHigh)
        case .clampMouse:
            var low = position(mem, Hole.lowLow, Hole.lowHigh), high = position(mem, Hole.highLow, Hole.highHigh)
            if low > high {
                // Bounds in the low bytes alone, signed, the high bytes left 0 (Robot Odyssey's).
                low = Int(Int8(bitPattern: mem[Hole.lowLow]))
                high = Int(Int8(bitPattern: mem[Hole.highLow]))
            }
            guard low <= high else { break }
            if a & 1 == 0 { clamp.x = low ... high } else { clamp.y = low ... high }
        case .homeMouse:
            (x, y) = (clamp.x.lowerBound, clamp.y.lowerBound)
            putPosition(&mem)
        case .initMouse:
            let once = reportsClickOnce
            self = MouseCard()
            reportsClickOnce = once
            mem[Hole.mode] = 0
            putPosition(&mem)
        }
        return false
    }

    private func position(_ mem: [UInt8], _ low: Int, _ high: Int) -> Int {
        Int(Int16(bitPattern: UInt16(mem[low]) | UInt16(mem[high]) << 8))
    }

    private func putPosition(_ mem: inout [UInt8]) {
        let (px, py) = (UInt16(truncatingIfNeeded: x), UInt16(truncatingIfNeeded: y))
        mem[Hole.xLow] = UInt8(px & 0xFF)
        mem[Hole.xHigh] = UInt8(px >> 8)
        mem[Hole.yLow] = UInt8(py & 0xFF)
        mem[Hole.yHigh] = UInt8(py >> 8)
    }
}
