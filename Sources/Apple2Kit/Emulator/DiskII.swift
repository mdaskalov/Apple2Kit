/// The Disk II controller card with two drives, at the nibble level: the
/// card's 16 switches ($C0n0-$C0nF, n = slot + 8) move the head, switch the
/// motor, pick a drive and read or write the disk's nibbles through the data
/// latch.  The boot ROM (P5, 256 bytes at $Cn00) is the machine's to map
/// (`Apple2Machine`).
///
/// Timing, simplified (Docs/DiskII.md): a nibble reads with bit 7 set once,
/// then, read again within 32 cycles, without (the latch shifting); the next
/// read takes the next nibble.  Code reading in a tight loop gets the disk's
/// nibbles faster than a real drive turns, never missing one; code away for
/// longer finds the disk turned on by the time it was away (32 cycles a
/// nibble).  After $C0n8 the motor runs on for a second, as the card's timer
/// keeps it.  Code that counts the cycles between nibbles (some copy
/// protection) can fail.
public nonisolated final class DiskII {
    public final class Drive {
        public internal(set) var image: DiskImage?
        /// The head, in half tracks (0-69).
        var halfTrack = 0
        /// The stepper motor's four magnets (bit n = phase n on).
        var phases: UInt8 = 0
        /// The next nibble under the head.
        var position = 0
        var writeProtected = false

        public var track: Int { halfTrack / 2 }
    }

    /// Cycles a nibble takes to pass the head (8 bits of 4 µs).
    static let cyclesPerNibble: UInt64 = 32
    /// After $C0n8 the drive spins on this long (the card's timer, about a
    /// second): DOS switches the motor off after each call and expects it
    /// still turning at the next one, else it waits for it to come up to speed.
    static let spinDownCycles: UInt64 = 1_000_000

    public let drives = [Drive(), Drive()]
    public private(set) var selected = 0
    private var motor = false
    /// The cycle the motor stops, after $C0n8.
    private var motorStops: UInt64?
    /// The CPU's cycle at the last access.
    private var now: UInt64 = 0
    private var q6 = false, q7 = false
    /// The data register: the last nibble read, the next to be written.
    private var latch: UInt8 = 0
    /// The cycle the latch took its nibble.
    private var latchCycle: UInt64 = 0
    /// The latch's nibble was read with bit 7 set: read again soon, it is
    /// shifting (bit 7 clear).
    private var latchRead = false

    var drive: Drive { drives[selected] }

    /// The selected drive's motor turns (still, after $C0n8, for a while).
    var motorOn: Bool {
        if motor, let stop = motorStops, now >= stop {
            motor = false
            motorStops = nil
        }
        return motor
    }

    /// Whether the motor turns at CPU cycle `cycles`.
    public func motorOn(at cycles: UInt64) -> Bool {
        now = max(now, cycles)
        return motorOn
    }

    /// An independent controller in the same state, with copies of the
    /// drives and their disks (`Apple2Machine.copy`).
    func copy() -> DiskII {
        let c = DiskII()
        for (mine, theirs) in zip(drives, c.drives) {
            (theirs.image, theirs.halfTrack, theirs.phases) = (mine.image, mine.halfTrack, mine.phases)
            (theirs.position, theirs.writeProtected) = (mine.position, mine.writeProtected)
        }
        (c.selected, c.motor, c.motorStops, c.now) = (selected, motor, motorStops, now)
        (c.q6, c.q7, c.latch, c.latchCycle, c.latchRead) = (q6, q7, latch, latchCycle, latchRead)
        return c
    }

    /// The controller as after a power cycle (the drives keep their disks).
    func reset() {
        motor = false
        motorStops = nil
        q6 = false
        q7 = false
        selected = 0
        latchRead = false
    }

    /// An access to switch `n` (0-15) of the card at CPU cycle `cycles`: a
    /// read, or a write of `value`.
    func access(_ n: Int, write: Bool, value: UInt8, cycles: UInt64) -> UInt8 {
        now = cycles
        switch n {
        case 0 ... 7: step(phase: n >> 1, on: n & 1 != 0)
        case 8: if motorOn && motorStops == nil { motorStops = cycles + DiskII.spinDownCycles }
        case 9: motor = true; motorStops = nil
        case 0xA: selected = 0
        case 0xB: selected = 1
        case 0xC: q6 = false
        case 0xD: q6 = true
        case 0xE: q7 = false
        default: q7 = true
        }
        // Q7 high with Q6 high: a write loads the latch; Q6 low shifts it out.
        if write && q7 && q6 { latch = value }
        if n == 0xC { return q7 ? writeNibble() : readNibble() }
        guard n & 1 == 0 else { return 0 }
        // Q6 high, Q7 low: the write-protect switch on bit 7
        if q6 && !q7 { return drive.writeProtected || drive.image == nil ? 0x80 : 0 }
        return latch
    }

    /// $C0nC in read mode: the latch (`DiskII` has the timing).
    private func readNibble() -> UInt8 {
        let d = drive
        guard motorOn, let image = d.image else { return latch }
        let elapsed = now &- latchCycle
        if latchRead && elapsed < DiskII.cyclesPerNibble {
            latchRead = false
            return latch & 0x7F
        }
        let nibbles = image.nibbles[min(d.track, DiskImage.tracks - 1)]
        if elapsed >= 2 * DiskII.cyclesPerNibble {
            d.position += Int(min(elapsed / DiskII.cyclesPerNibble, UInt64(nibbles.count))) - 1
        }
        d.position %= nibbles.count
        latch = nibbles[d.position]
        d.position += 1
        latchCycle = now
        latchRead = true
        return latch
    }

    /// $C0nC in write mode: the latch onto the disk, one nibble on.
    private func writeNibble() -> UInt8 {
        let d = drive
        guard motorOn, d.image != nil else { return latch }
        // no local copy of the image: the write would copy the track
        let track = min(d.track, DiskImage.tracks - 1)
        d.position %= d.image!.nibbles[track].count
        if !d.writeProtected { d.image!.write(latch, track: track, position: d.position) }
        d.position += 1
        latchCycle = now
        latchRead = false
        return latch
    }

    /// A magnet of the head's stepper switched: the head moves half a track
    /// towards a magnet that is on next to the one it is at (half track h is
    /// at magnet h mod 4).
    private func step(phase: Int, on: Bool) {
        let d = drive
        if on { d.phases |= 1 << phase } else { d.phases &= ~(1 << phase) }
        let at = d.halfTrack & 3
        var move = 0
        if d.phases & 1 << ((at + 1) & 3) != 0 { move += 1 }
        if d.phases & 1 << ((at + 3) & 3) != 0 { move -= 1 }
        guard move != 0 else { return }
        let track = d.track
        d.halfTrack = max(0, min(2 * (DiskImage.tracks - 1) + 1, d.halfTrack + move))
        if d.track != track, let image = d.image {
            // keep the angle: the same fraction of the way round the new track
            let old = image.nibbles[min(track, DiskImage.tracks - 1)].count
            let new = image.nibbles[min(d.track, DiskImage.tracks - 1)].count
            if old != new { d.position = d.position * new / max(old, 1) }
        }
    }

    // MARK: disks

    public func insert(_ image: DiskImage, drive n: Int) {
        drives[n].image = image
        drives[n].position = 0
    }

    /// Takes the disk out of drive `n` and returns it.
    @discardableResult
    public func eject(drive n: Int) -> DiskImage? {
        defer { drives[n].image = nil }
        return drives[n].image
    }

    public var hasDisk: Bool { drives.contains { $0.image != nil } }
}
