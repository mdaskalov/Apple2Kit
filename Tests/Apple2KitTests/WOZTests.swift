import Foundation
import Testing
@testable import Apple2Kit

/// `.woz` images, built here from sector data: no ROMs or disk files needed.
@Suite struct WOZTests {
    /// 140K of DOS-order sectors, each byte telling its track, sector and offset.
    static let sectors: [UInt8] = (0 ..< DiskImage.sectorImageSize).map {
        UInt8(truncatingIfNeeded: $0 / DiskImage.trackSize &* 7 &+ $0 / 256 &* 13 &+ $0)
    }

    /// The tracks of `sectors` as bits, the self-sync FFs 10 bits long.
    static let trackBits: [WOZ.Track] = (0 ..< DiskImage.tracks).map {
        let nibbles = physical(DiskImage.nibblize(track: $0, of: sectors, order: .dos))
        return WOZ.bits(nibbles: nibbles, lengths: syncLengths(nibbles))
    }

    /// The lengths DOS writes: 10 bits for the FFs of a gap (a run of them),
    /// 8 for the rest, an FF in a field too (volume 254 is FF FE).
    static func syncLengths(_ nibbles: [UInt8]) -> [UInt8] {
        nibbles.indices.map { k in
            let ff = { (i: Int) in nibbles[(i + nibbles.count) % nibbles.count] == 0xFF }
            return ff(k) && (ff(k - 1) || ff(k + 1)) ? 10 : 8
        }
    }

    /// A nibblized track as long as a real one (about 51000 bits): runs of
    /// FF cut to 20.
    static func physical(_ nibbles: [UInt8]) -> [UInt8] {
        var out = [UInt8](), run = 0
        for n in nibbles {
            run = n == 0xFF ? run + 1 : 0
            if run <= 20 { out.append(n) }
        }
        return out
    }

    /// The standard map: track t at quarter tracks 4t-1 to 4t+1.
    static let tmap: [UInt8] = (0 ..< 160).map { q in
        let t = (q + 1) / 4
        return (q + 1) % 4 != 3 && t < DiskImage.tracks ? UInt8(t) : 0xFF
    }

    static func header(_ version: Character) -> [UInt8] {
        Array("WOZ\(version)".utf8) + [0xFF, 0x0A, 0x0D, 0x0A, 0, 0, 0, 0]
    }

    static func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
        var out = Array(id.utf8)
        WOZ.append32(UInt32(body.count), to: &out)
        return out + body
    }

    static func info(version: UInt8, writeProtected: Bool = false) -> [UInt8] {
        var info = [UInt8](repeating: 0, count: 60)
        (info[0], info[1], info[2]) = (version, 1, writeProtected ? 1 : 0)
        info.replaceSubrange(5 ..< 37, with: Array("Apple2Kit tests".padding(toLength: 32, withPad: " ", startingAt: 0).utf8))
        return info
    }

    static func woz2(tracks: [WOZ.Track] = trackBits, writeProtected: Bool = false, bitTiming: UInt8 = 0) -> [UInt8] {
        var entries = [UInt8](), bits = [UInt8](), block = 3
        for i in 0 ..< 160 {
            guard i < tracks.count else { entries += [UInt8](repeating: 0, count: 8); continue }
            let t = tracks[i], n = (t.bytes.count + 511) / 512
            WOZ.append16(UInt16(block), to: &entries)
            WOZ.append16(UInt16(n), to: &entries)
            WOZ.append32(UInt32(t.count), to: &entries)
            bits += t.bytes + [UInt8](repeating: 0, count: n * 512 - t.bytes.count)
            block += n
        }
        var info = info(version: 2, writeProtected: writeProtected)
        info[39] = bitTiming
        return header("2") + chunk("INFO", info) + chunk("TMAP", tmap) + chunk("TRKS", entries + bits)
    }

    static func woz1() -> [UInt8] {
        var trks = [UInt8]()
        for t in trackBits {
            var record = t.bytes + [UInt8](repeating: 0, count: 6646 - t.bytes.count)
            WOZ.append16(UInt16(t.bytes.count), to: &record)
            WOZ.append16(UInt16(t.count), to: &record)
            record += [UInt8](repeating: 0, count: 6)
            trks += record
        }
        return header("1") + chunk("INFO", info(version: 1)) + chunk("TMAP", tmap) + chunk("TRKS", trks)
    }

    /// The sectors read back from each track of `image`, in DOS order.
    static func readSectors(_ image: DiskImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: DiskImage.sectorImageSize)
        for t in 0 ..< DiskImage.tracks {
            let found = DiskImage.denibblize(image.track(atHalfTrack: 2 * t), track: t)
            #expect(found.count == 16, "track \(t)")
            for (physical, bytes) in found {
                let offset = t * DiskImage.trackSize + Int(SectorOrder.dos.imageSector[physical]) * 256
                out.replaceSubrange(offset ..< offset + 256, with: bytes)
            }
        }
        return out
    }

    @Test func readsWOZ2() throws {
        let image = try DiskImage(name: "test.woz", data: Self.woz2())
        #expect(image.format == .woz)
        #expect(!image.isWriteProtected)
        #expect(Self.readSectors(image) == Self.sectors)
        // half tracks between tracks and tracks 35-39: unformatted
        #expect(image.track(atHalfTrack: 1) == DiskImage.unformatted)
        #expect(image.track(atHalfTrack: 75) == DiskImage.unformatted)
    }

    @Test func readsWOZ1() throws {
        let image = try DiskImage(name: "test.woz", data: Self.woz1())
        #expect(image.format == .woz)
        #expect(Self.readSectors(image) == Self.sectors)
    }

    /// A track whose bits start in the middle of a byte: the latch falls
    /// into step on the self-sync FFs.
    @Test func bitsOutOfStep() {
        let t = Self.trackBits[17]
        var bools = (0 ..< t.count).map { t.bytes[$0 / 8] >> (7 - $0 % 8) & 1 }
        bools = Array(bools[1237...] + bools[..<1237])
        var bytes = [UInt8](repeating: 0, count: (t.count + 7) / 8)
        for (i, b) in bools.enumerated() { bytes[i / 8] |= b << (7 - i % 8) }
        let nibbles = WOZ.nibbles(bits: bytes, count: t.count).nibbles
        #expect(DiskImage.denibblize(nibbles, track: 17).count == 16)
    }

    @Test func writeProtected() throws {
        let image = try DiskImage(name: "test.woz", data: Self.woz2(writeProtected: true))
        #expect(image.isWriteProtected)
        let disk = DiskII()
        disk.insert(image, drive: 0)
        #expect(disk.drives[0].writeProtected)
    }

    @Test func rejectsBadFiles() {
        var data = Self.woz2()
        data[21] = 2                    // INFO disk type: 3.5"
        #expect(throws: (any Error).self) { try DiskImage(name: "test.woz", data: data) }
        #expect(throws: (any Error).self) { try DiskImage(name: "test.woz", data: Array(Self.woz2().prefix(300))) }
    }

    /// Writing a track and saving: the written track decodes to the new
    /// sectors, the others keep their bits, the CRC is right, and a track
    /// written where there was none (track 36) is in the map.
    @Test func writeAndSave() throws {
        var image = try DiskImage(name: "test.woz", data: Self.woz1())
        var changed = Self.sectors
        for i in 5 * DiskImage.trackSize ..< 6 * DiskImage.trackSize { changed[i] ^= 0x5A }
        let track5 = Self.physical(DiskImage.nibblize(track: 5, of: changed, order: .dos))
        for (i, (n, bits)) in zip(track5, Self.syncLengths(track5)).enumerated() {
            image.write(n, halfTrack: 10, position: i)
            image.setLength(Int(bits), halfTrack: 10, position: i)
        }
        let track36 = DiskImage.nibblize(track: 36 % 35, of: Self.sectors, order: .dos)
        for (i, n) in track36.prefix(6400).enumerated() { image.write(n, halfTrack: 72, position: i) }
        #expect(image.isModified)

        let data = image.fileData()
        #expect(!image.isModified)
        #expect(data[0 ..< 4].elementsEqual("WOZ2".utf8))
        #expect(WOZ.u32(data, 8) == WOZ.crc32(data[12...]))

        let saved = try DiskImage(name: "test.woz", data: data)
        #expect(Self.readSectors(saved) == changed)
        let woz = try WOZ(data)
        #expect(woz.tracks[4].bytes == Self.trackBits[4].bytes)
        #expect(woz.map[143 ... 145].allSatisfy { $0 != WOZ.noTrack })
        #expect(saved.track(atHalfTrack: 72) != DiskImage.unformatted)
        // the written track: its nibbles at the lengths written
        #expect(woz.tracks[5].count == Self.trackBits[5].count)
    }

    /// Nibbles a read finds keep their lengths: an address field's FF (the
    /// volume) stays 8 bits, the gaps' FFs 10.
    @Test func lengthsAsRead() throws {
        let t = Self.trackBits[3]
        let (nibbles, lengths) = WOZ.nibbles(bits: t.bytes, count: t.count)
        let k = try #require(nibbles.indices.first { nibbles[$0 ..< $0 + 3].elementsEqual([0xD5, 0xAA, 0x96]) })
        #expect(nibbles[k + 3] == 0xFF && lengths[k + 3] == 8)
        #expect(lengths[k - 1] == 10 && nibbles[k - 1] == 0xFF)
        #expect(WOZ.bits(nibbles: nibbles, lengths: lengths).count == t.count)
    }

    /// The controller writing as DOS does, a sync FF 40 cycles before the
    /// next nibble, data 32 apart: the saved bits have FFs of 10 bits and
    /// the rest of 8.
    @Test func writeTiming() throws {
        let disk = DiskII()
        disk.insert(try DiskImage(name: "test.woz", data: Self.woz2()), drive: 0)
        _ = disk.access(9, write: false, value: 0, cycles: 0)          // motor on
        _ = disk.access(0xF, write: false, value: 0, cycles: 10)       // write mode
        var cycle: UInt64 = 1000
        for (value, gap) in [(0xFF, 40), (0xFF, 40), (0xFF, 40), (0x96, 32), (0x97, 32), (0x9A, 32)] as [(UInt8, UInt64)] {
            _ = disk.access(0xD, write: true, value: value, cycles: cycle - 4)   // load
            _ = disk.access(0xC, write: false, value: 0, cycles: cycle)          // shift out
            cycle += gap
        }
        var image = try #require(disk.drives[0].image)
        let woz = try WOZ(image.fileData())
        let read = WOZ.nibbles(bits: woz.tracks[0].bytes, count: woz.tracks[0].count)
        let (nibbles, lengths) = (read.nibbles + read.nibbles, read.lengths + read.lengths)   // round
        let k = try #require(read.nibbles.indices.first { nibbles[$0 ..< $0 + 5].elementsEqual([0xFF, 0xFF, 0xFF, 0x96, 0x97]) })
        #expect(Array(lengths[k ..< k + 5]) == [10, 10, 10, 8, 8])
    }

    /// An "E7 bitstream": a run of E7s, some with one or two 0 bits after
    /// them.  Read in step they are E7s; after $C0nD clears the shift
    /// register right after the third, the bits read as other nibbles.  The
    /// check reads as protection code does (a 7-cycle `LDA $C0EC / BPL`
    /// loop, then a compare) and needs EE, then E7 FC EE E7 FC EE EE FC,
    /// within 16 nibbles.
    @Test func bitSlip() throws {
        let field: [UInt8] = [0xD5, 0xAA, 0xAD] + [UInt8](repeating: 0x96, count: 20) + [UInt8](repeating: 0xE7, count: 40)
        var fieldLengths = [UInt8](repeating: 8, count: field.count)
        let slips: [UInt8] = [9, 9, 8, 8, 10, 8, 9, 10, 8, 9, 10, 8, 9, 9]
        fieldLengths.replaceSubrange(23 ..< 23 + slips.count, with: slips)
        let nibbles = Self.physical(DiskImage.nibblize(track: 7, of: Self.sectors, order: .dos))
        let gap = try #require(nibbles.indices.first { nibbles[$0 ..< $0 + 20].allSatisfy { $0 == 0xFF } })
        var tracks = Self.trackBits
        tracks[7] = WOZ.bits(nibbles: Array(nibbles[..<(gap + 10)]) + field + nibbles[(gap + 10)...],
                             lengths: Self.syncLengths(Array(nibbles[..<(gap + 10)])) + fieldLengths
                                 + Self.syncLengths(Array(nibbles[(gap + 10)...])))

        func check(disk: DiskII) -> [UInt8] {
            var cycle: UInt64 = 0
            func read() -> UInt8 { Self.readNibble(disk, at: &cycle) }
            while read() != 0xD5 {}
            while read() != 0xE7 {}
            guard read() == 0xE7, read() == 0xE7 else { return [] }
            cycle += 8                                              // CMP, BNE, LDA $C0ED
            _ = disk.access(0xD, write: false, value: 0, cycles: cycle)
            cycle += 3                                              // BIT
            for _ in 0 ..< 16 where read() == 0xEE {
                // each against the signature: CMP table,Y / BNE / INY / CPY / BNE
                return (0 ..< 8).map { _ in defer { cycle += 9 }; return read() }
            }
            return []
        }
        let disk = DiskII()
        disk.insert(try DiskImage(name: "test.woz", data: Self.woz2(tracks: tracks)), drive: 0)
        _ = disk.access(9, write: false, value: 0, cycles: 0)      // motor on
        for _ in 0 ..< 28 { _ = disk.access(0, write: false, value: 0, cycles: 0) }
        // to half track 14 (track 7): phases 1, 2, 3, 0 … on in turn
        for h in 1 ... 14 {
            _ = disk.access(2 * ((h - 1) & 3), write: false, value: 0, cycles: 0)
            _ = disk.access(2 * (h & 3) + 1, write: false, value: 0, cycles: 0)
        }
        _ = disk.access(2 * (14 & 3), write: false, value: 0, cycles: 0)
        #expect(disk.drives[0].track == 7)
        #expect(check(disk: disk) == [0xE7, 0xFC, 0xEE, 0xE7, 0xFC, 0xEE, 0xEE, 0xFC])
        // and in step again: the track's sectors read
        var after = [UInt8]()
        var cycle: UInt64 = 100_000
        while after.count < 7000 { after.append(Self.readNibble(disk, at: &cycle)) }
        #expect(DiskImage.denibblize(after, track: 7).count == 16)
    }

    /// The next nibble as RWTS reads it: `LDA $C0EC,X / BPL` (7 cycles a
    /// try), then 4 cycles to compare it.
    static func readNibble(_ disk: DiskII, at cycle: inout UInt64) -> UInt8 {
        while true {
            cycle += 7
            let v = disk.access(0xC, write: false, value: 0, cycles: cycle)
            if v & 0x80 != 0 {
                cycle += 4
                return v
            }
        }
    }

    /// Track 0 as sync FFs, then D5 AA 96 and distinct nibbles (`marked`);
    /// `lengths` changes some nibbles' lengths in bits (by index there).
    static func markedDisk(bitTiming: UInt8 = 0, lengths: [Int: UInt8] = [:]) throws -> (DiskII, [UInt8]) {
        let marks = Array(DiskImage.writeTable.dropFirst())         // 96 is in the mark
        let nibbles = [UInt8](repeating: 0xFF, count: 40) + [0xD5, 0xAA, 0x96] + marks
        var bits = [UInt8](repeating: 10, count: 40) + [UInt8](repeating: 8, count: 3 + marks.count)
        for (i, l) in lengths { bits[40 + i] = l }
        var tracks = trackBits
        tracks[0] = WOZ.bits(nibbles: nibbles, lengths: bits)
        let disk = DiskII()
        disk.insert(try DiskImage(name: "test.woz", data: woz2(tracks: tracks, bitTiming: bitTiming)), drive: 0)
        _ = disk.access(9, write: false, value: 0, cycles: 0)      // motor on
        return (disk, [0xD5, 0xAA, 0x96] + marks)
    }

    /// The disk turns with the clock: RWTS's loop gets each nibble once, as
    /// the disk brings it (32 cycles; 28 at a 3.5 µs bit timing), not
    /// sooner.  Copy protection times the disk this way.
    @Test(arguments: [(UInt8(0), UInt64(32)), (28, 28)]) func diskTurnsWithTheClock(timing: UInt8, nibble: UInt64) throws {
        let (disk, marked) = try Self.markedDisk(bitTiming: timing)
        var cycle: UInt64 = 1000
        func read() -> UInt8 { disk.access(0xC, write: false, value: 0, cycles: cycle) }
        while read() != 0xD5 { cycle += 1 }                         // in as it comes
        let start = cycle
        cycle += 4                                                  // CMP / BNE
        var got = [UInt8]()
        while cycle < start + 20 * nibble { got.append(Self.readNibble(disk, at: &cycle)) }
        #expect(got == Array(marked[1 ... 20]))
    }

    /// The latch holds a nibble through the 0s after it: read again 12
    /// cycles later, a D5 with three 0s after it is still there (protection
    /// looks twice), an AA with none has moved on (bit 7 clear).
    @Test func latchHoldsThroughZeros() throws {
        let (disk, _) = try Self.markedDisk(lengths: [0: 11])
        var cycle: UInt64 = 1000
        func read() -> UInt8 { disk.access(0xC, write: false, value: 0, cycles: cycle) }
        while read() != 0xD5 { cycle += 1 }
        cycle += 12
        #expect(read() == 0xD5)
        while read() != 0xAA { cycle += 1 }
        cycle += 12
        #expect(read() & 0x80 == 0)
    }

    /// Weak bits: where the disk has no 1 bits for a while the drive reads
    /// random ones, so a stretch of 20 0s reads differently on each turn
    /// (copy protection checks that a copy doesn't read the same).  Three
    /// 0s are no stretch: those read the same every time.
    @Test(arguments: [(UInt8(28), true), (11, false)]) func weakBits(length: UInt8, differ: Bool) throws {
        let (disk, _) = try Self.markedDisk(lengths: [3: length])     // 97, ends in a 1
        var cycle: UInt64 = 1000
        var turns = Set<[UInt8]>()
        for _ in 0 ..< 6 {
            while Self.readNibble(disk, at: &cycle) != 0xD5 {}
            turns.insert((0 ..< 10).map { _ in Self.readNibble(disk, at: &cycle) })
        }
        #expect((turns.count > 1) == differ)
    }

    @Test func crc32() {
        #expect(WOZ.crc32(Array("123456789".utf8)[...]) == 0xCBF4_3926)
    }
}
