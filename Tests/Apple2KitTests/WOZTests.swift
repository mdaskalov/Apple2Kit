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

    static func woz2(tracks: [WOZ.Track] = trackBits, writeProtected: Bool = false) -> [UInt8] {
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
        return header("2") + chunk("INFO", info(version: 2, writeProtected: writeProtected))
            + chunk("TMAP", tmap) + chunk("TRKS", entries + bits)
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

    @Test func crc32() {
        #expect(WOZ.crc32(Array("123456789".utf8)[...]) == 0xCBF4_3926)
    }
}
