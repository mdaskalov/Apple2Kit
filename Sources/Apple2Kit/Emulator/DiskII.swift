/// The Disk II controller card with two drives, at the nibble level: the
/// card's 16 switches ($C0n0-$C0nF, n = slot + 8) move the head, switch the
/// motor, pick a drive and read or write the disk's nibbles through the data
/// latch.  The boot ROM (P5, 256 bytes at $Cn00) is the machine's to map
/// (`Apple2Machine`).
///
/// Timing (Docs/DiskII.md).  A `.woz` is read bit by bit as the disk
/// turns with the CPU's clock (a bit every 4 cycles, or the image's bit
/// timing): the bits go through the shift register into the latch as the
/// card's sequencer has them, so a nibble is there while the latch holds it
/// (through the 0s after it), $C0nD clears the register ("E7 bitstream"
/// copy protection), and where the disk has no 1 bits for a while the
/// drive reads random ones (weak bits).  A `.dsk`/`.nib` has no bits
/// between its nibbles and is read a nibble at a time, 32 cycles each: the
/// first read of a nibble has bit 7 set, later ones see it shifting (bit 7
/// clear).  After $C0n8 the motor runs on for a second, as the card's timer
/// keeps it.
public nonisolated final class DiskII {
    public final class Drive {
        public internal(set) var image: DiskImage?
        /// The head, in half tracks (0-79).
        var halfTrack = 0
        /// The stepper motor's four magnets (bit n = phase n on).
        var phases: UInt8 = 0
        /// The next nibble under the head; a `.woz`: the nibble the head is
        /// in, `offset` bits into it (its 8, then the 0s after it).
        var position = 0
        var offset = 0
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
    /// The cycle the latch took its nibble, and eighths of a cycle after it
    /// (bits of 3.5 µs, `DiskImage.bitTiming`).
    private var latchCycle: UInt64 = 0
    private var latchEighths: UInt64 = 0
    /// The latch's nibble was read with bit 7 set: read again soon, it is
    /// shifting (bit 7 clear).
    private var latchRead = false
    /// The last access to the latch wrote a nibble.
    private var writing = false
    // A `.woz` (`readWOZ`): the sequencer's shift register; how many more
    // bits the latch holds its nibble; the last 4 bits under the head; the
    // time the next bit is under it, in eighths of a cycle.
    private var shift: UInt8 = 0
    private var hold = 0
    private var window: UInt8 = 0
    private var bitTime: UInt64 = 0
    /// For weak bits (xorshift).
    private var random: UInt64 = 0x9E37_79B9_7F4A_7C15

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
            (theirs.position, theirs.offset, theirs.writeProtected) = (mine.position, mine.offset, mine.writeProtected)
        }
        (c.selected, c.motor, c.motorStops, c.now) = (selected, motor, motorStops, now)
        (c.q6, c.q7, c.latch, c.latchCycle, c.latchRead, c.writing) = (q6, q7, latch, latchCycle, latchRead, writing)
        (c.latchEighths, c.shift, c.hold, c.window, c.bitTime, c.random) = (latchEighths, shift, hold, window, bitTime, random)
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
        writing = false
        shift = 0
        hold = 0
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
        case 0xD:
            // read mode: the sequencer to state 0, the register cleared, the
            // latch the write-protect switch (a `.woz`: the next 1 bit
            // starts a nibble, wherever it is)
            if !q7 && motorOn, let image = drive.image, image.format == .woz {
                _ = readWOZ()
                (shift, hold, latch) = (0, 0, drive.writeProtected ? 0xFF : 0)
            }
            q6 = true
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
        if image.format == .woz { return readWOZ() }
        writing = false
        let nibbles = image.track(atHalfTrack: d.halfTrack)
        let lengths = image.lengths(atHalfTrack: d.halfTrack)
        d.position %= nibbles.count
        // in eighths of a cycle, the time from nibble i - 1 to nibble i: a
        // nibble is in when its 8th bit is, the 0s after it delay the next
        let timing = UInt64(image.bitTiming)
        func eighths(_ i: Int) -> UInt64 {
            UInt64(lengths?[(i + nibbles.count - 1) % nibbles.count] ?? 8) * timing
        }
        var elapsed = (now &- latchCycle) * 8 &- latchEighths
        if elapsed >= 64 * 8 * DiskII.cyclesPerNibble {
            // away for long: whole turns don't matter
            let turn = UInt64(lengths?.reduce(0) { $0 + Int($1) } ?? 8 * nibbles.count) * timing
            elapsed %= turn
        }
        // the nibbles that came in since the last one: the latch has the newest
        var time = now * 8 &- elapsed
        while elapsed >= eighths(d.position) {
            let e = eighths(d.position)
            latch = nibbles[d.position]
            time &+= e
            elapsed -= e
            d.position = (d.position + 1) % nibbles.count
            latchRead = false
        }
        (latchCycle, latchEighths) = (time / 8, time % 8)
        // The first read of a nibble has bit 7.  So do later ones while the
        // latch holds it: through the 0s after it, until the next 1 bit
        // (a bit on); after that it is shifting.  Code can look twice at a
        // nibble with 0s after it (copy protection does).
        let held = (UInt64(lengths?[(d.position + nibbles.count - 1) % nibbles.count] ?? 8) - 7) * timing
        if latchRead && elapsed >= held { return latch & 0x7F }
        latchRead = true
        return latch
    }

    /// $C0nC in read mode on a `.woz`: the bits that passed the head since
    /// the last access go through the sequencer, the latch as it is now.
    /// The head sees 4 bits at a time (the MC3470 amplifier): where they are
    /// all 0 it has turned its gain up and reads noise, a 1 about 3 times
    /// in 10 (weak bits, WOZ reference); else it reads the disk, a bit late.
    /// The register shifts the bits in; when bit 7 is set it is a nibble,
    /// the latch takes it and holds it through the 0s that follow and 2 bits
    /// more, the register starts again at the next 1 (AppleWin's
    /// `DataLatchReadWOZ`).
    private func readWOZ() -> UInt8 {
        let d = drive
        guard motorOn, let image = d.image, let lengths = image.lengths(atHalfTrack: d.halfTrack) else { return latch }
        let nibbles = image.track(atHalfTrack: d.halfTrack)
        let timing = UInt64(image.bitTiming)
        let now8 = now * 8
        if writing {
            // back from writing: the head is at the nibble after the last
            writing = false
            (d.offset, shift, hold, bitTime) = (0, 0, 0, now8)
        }
        d.position %= nibbles.count
        let count = now8 > bitTime ? (now8 - bitTime) / timing : 0
        if count > 2048 {
            // away for long (the motor was off): the last 1024 bits will do
            var skip = Int(count - 1024) % lengths.reduce(0) { $0 + Int($1) }
            bitTime = now8 - 1024 * timing
            while skip > 0 {
                let rest = min(skip, Int(lengths[d.position]) - d.offset)
                skip -= rest
                d.offset += rest
                if d.offset >= Int(lengths[d.position]) { (d.position, d.offset) = ((d.position + 1) % nibbles.count, 0) }
            }
        }
        while bitTime + timing <= now8 {
            bitTime += timing
            let bit = d.offset < 8 ? nibbles[d.position] >> (7 - d.offset) & 1 : 0
            d.offset += 1
            if d.offset >= Int(lengths[d.position]) {
                (d.position, d.offset) = ((d.position + 1) % nibbles.count, 0)
                // Round once: a real drive's speed varies a little, the next
                // bit comes up to 2 bits later.  Code that retries a check
                // a turn later doesn't meet the same timing every time.
                if d.position == 0 { bitTime += nextRandom() % (2 * timing) }
            }
            window = (window << 1 | bit) & 0xF
            let out: UInt8
            if window != 0 {
                out = window >> 1 & 1
            } else {
                out = nextRandom() % 10 < 3 ? 1 : 0
            }
            shift = shift << 1 | out
            if hold > 0 {
                hold -= 1
                if shift == 0 { hold += 1 }                     // 0s: held on
            }
            if hold == 0 {
                latch = shift
                if shift & 0x80 != 0 { (hold, shift) = (2, 0) }
            }
        }
        return latch
    }

    /// The next of a fixed run of pseudo-random numbers (xorshift).
    private func nextRandom() -> UInt64 {
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return random
    }

    /// $C0nC in write mode: the latch onto the disk, one nibble on.
    private func writeNibble() -> UInt8 {
        let d = drive
        guard motorOn, d.image != nil else { return latch }
        if !writing && d.offset > 0 { (d.position, d.offset) = (d.position + 1, 0) }
        // no local copy of the image: the write would copy the track
        d.position %= d.image!.track(atHalfTrack: d.halfTrack).count
        if !d.writeProtected {
            // the nibble before was as long as the time since it: 32 cycles,
            // 8 bits; 40 a self-sync FF of 10 (a .woz keeps it)
            if writing {
                d.image!.setLength(Int((now &- latchCycle + 2) / 4), halfTrack: d.halfTrack, position: d.position - 1)
            }
            d.image!.write(latch, halfTrack: d.halfTrack, position: d.position)
        }
        writing = true
        d.position += 1
        (latchCycle, latchEighths) = (now, 0)
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
        let from = d.halfTrack
        d.halfTrack = max(0, min(2 * DiskImage.maxTracks - 1, d.halfTrack + move))
        if d.halfTrack != from, let image = d.image {
            // keep the angle: the same fraction of the way round the new track
            let old = image.track(atHalfTrack: from).count
            let new = image.track(atHalfTrack: d.halfTrack).count
            if old != new { d.position = d.position * new / max(old, 1) }
            d.offset = 0
        }
    }

    // MARK: disks

    public func insert(_ image: DiskImage, drive n: Int) {
        drives[n].image = image
        drives[n].position = 0
        drives[n].offset = 0
        drives[n].writeProtected = image.isWriteProtected
    }

    /// Takes the disk out of drive `n` and returns it.
    @discardableResult
    public func eject(drive n: Int) -> DiskImage? {
        defer { drives[n].image = nil }
        return drives[n].image
    }

    public var hasDisk: Bool { drives.contains { $0.image != nil } }
}
