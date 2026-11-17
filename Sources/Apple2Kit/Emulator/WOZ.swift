import Foundation

/// A `.woz` file (WOZ 1 or 2, 5.25" disks): the bits of each track as a
/// drive reads them off the disk, and a map of which track the head finds at
/// each quarter track (Docs/DiskII.md).
///
///     header   "WOZ1"/"WOZ2", FF 0A 0D 0A, CRC32 of the rest
///     chunks   4-byte id, UInt32 size (little endian), the data:
///       INFO   60 bytes: version, disk type (1 = 5.25"), write protected, …
///       TMAP   160 bytes: by quarter track, the TRKS index ($FF: none)
///       TRKS   WOZ1: 6656-byte records, the bits then their counts
///              WOZ2: 160 × (start block, block count, bit count), the bits
///              in 512-byte blocks of the file
///       META   tab-separated key/value lines (kept as it is)
///
/// The emulator reads nibbles, so each track's bits go through the Disk II's
/// latch (`nibbles(bits:count:)`) once, when the file is read, keeping each
/// nibble's length in bits.  Saving writes a WOZ2 file: unwritten tracks
/// keep their bits as they were, written ones are their nibbles at their
/// lengths.
nonisolated struct WOZ {
    static let quarterTracks = 160
    static let blockSize = 512
    static let woz1TrackSize = 6656
    static let noTrack: UInt8 = 0xFF

    /// A track's bits, the first in bit 7 of `bytes[0]`.
    struct Track {
        var bytes: [UInt8]
        var count: Int
    }

    /// The 60 bytes of the INFO chunk.
    var info: [UInt8]
    /// By quarter track: the index in `tracks`, `noTrack` where there is none.
    var map: [UInt8]
    var tracks: [Track]
    /// The META chunk's data, nil: none.
    var meta: [UInt8]?

    var isWriteProtected: Bool { info[2] == 1 }
    /// How long a bit takes to pass the head, in 125 ns (WOZ2's optimal bit
    /// timing: 32, 4 µs, the Disk II's; some disks were written faster).
    var bitTiming: Int { info[39] == 0 ? 32 : Int(info[39]) }

    enum WOZError: LocalizedError {
        case bad(String)
        var errorDescription: String? {
            switch self { case .bad(let why): "not a usable .woz file: \(why)." }
        }
    }

    // MARK: reading

    static func isWOZ(_ data: [UInt8]) -> Bool {
        data.count >= 12 && (data[0 ..< 4].elementsEqual("WOZ1".utf8) || data[0 ..< 4].elementsEqual("WOZ2".utf8))
            && data[4 ..< 8].elementsEqual([0xFF, 0x0A, 0x0D, 0x0A])
    }

    init(_ data: [UInt8]) throws {
        guard WOZ.isWOZ(data) else { throw WOZError.bad("no WOZ1/WOZ2 header") }
        let version1 = data[3] == UInt8(ascii: "1")
        var info: [UInt8]?, map: [UInt8]?, trks: Range<Int>?, meta: [UInt8]?
        var at = 12
        while at + 8 <= data.count {
            let id = String(decoding: data[at ..< at + 4], as: UTF8.self)
            let size = Int(WOZ.u32(data, at + 4))
            let body = at + 8
            guard size <= data.count - body else { throw WOZError.bad("chunk \(id) runs past the end") }
            switch id {
            case "INFO" where size >= 60: info = Array(data[body ..< body + 60])
            case "TMAP" where size >= WOZ.quarterTracks: map = Array(data[body ..< body + WOZ.quarterTracks])
            case "TRKS": trks = body ..< body + size
            case "META": meta = Array(data[body ..< body + size])
            default: break     // WRIT, FLUX, unknown chunks
            }
            at = body + size
        }
        guard var info, let map, let trks else { throw WOZError.bad("no INFO, TMAP or TRKS chunk") }
        guard info[1] == 1 else { throw WOZError.bad("not a 5.25\" disk") }

        var tracks = [Track]()
        if version1 {
            for start in stride(from: trks.lowerBound, to: trks.upperBound - WOZ.woz1TrackSize + 1, by: WOZ.woz1TrackSize) {
                let bytesUsed = Int(WOZ.u16(data, start + 6646)), bits = Int(WOZ.u16(data, start + 6648))
                guard bytesUsed <= 6646, bits <= bytesUsed * 8 else { throw WOZError.bad("a track's bit count is wrong") }
                tracks.append(Track(bytes: Array(data[start ..< start + bytesUsed]), count: bits))
            }
            // the INFO of a WOZ2 file (what saving writes)
            info.replaceSubrange(37 ..< 60, with: [UInt8](repeating: 0, count: 23))
            (info[0], info[37], info[39]) = (2, 1, 32)
        } else {
            guard trks.count >= 8 * WOZ.quarterTracks else { throw WOZError.bad("the TRKS chunk is short") }
            for i in 0 ..< WOZ.quarterTracks {
                let e = trks.lowerBound + 8 * i
                let start = Int(WOZ.u16(data, e)) * WOZ.blockSize, blocks = Int(WOZ.u16(data, e + 2))
                let bits = Int(WOZ.u32(data, e + 4))
                let bytes = (bits + 7) / 8
                if bits == 0 { tracks.append(Track(bytes: [], count: 0)); continue }
                guard bytes <= blocks * WOZ.blockSize, start + bytes <= data.count else {
                    throw WOZError.bad("track \(i)'s bits are outside the file")
                }
                tracks.append(Track(bytes: Array(data[start ..< start + bytes]), count: bits))
            }
            // no FLUX chunk is written back
            info.replaceSubrange(46 ..< 50, with: [0, 0, 0, 0])
        }
        // tracks the map shows, renumbered in order (WOZ2 lists 160, most empty)
        var used = [Int: Int]()
        var kept = [Track]()
        self.map = map.map { i in
            guard i != WOZ.noTrack, Int(i) < tracks.count, tracks[Int(i)].count > 0 else { return WOZ.noTrack }
            if let n = used[Int(i)] { return UInt8(n) }
            used[Int(i)] = kept.count
            kept.append(tracks[Int(i)])
            return UInt8(kept.count - 1)
        }
        self.info = info
        self.tracks = kept
        self.meta = meta
    }

    // MARK: writing

    /// The file, as WOZ2.
    func fileData() -> [UInt8] {
        var out = Array("WOZ2".utf8) + [0xFF, 0x0A, 0x0D, 0x0A, 0, 0, 0, 0]
        func chunk(_ id: String, _ body: [UInt8]) {
            out += Array(id.utf8)
            WOZ.append32(UInt32(body.count), to: &out)
            out += body
        }
        let tracks = tracks.prefix(WOZ.quarterTracks)     // all TRKS has room for
        let blocks = tracks.map { ($0.bytes.count + WOZ.blockSize - 1) / WOZ.blockSize }
        var info = info
        let largest = blocks.max() ?? 0
        (info[44], info[45]) = (UInt8(largest & 0xFF), UInt8(largest >> 8))
        chunk("INFO", info)
        chunk("TMAP", map)
        // TRKS: the entries, then the bits from block 3 (1536 = 256 + 1280)
        var trks = [UInt8]()
        var block = 3
        for i in 0 ..< WOZ.quarterTracks {
            if i < tracks.count {
                WOZ.append16(UInt16(block), to: &trks)
                WOZ.append16(UInt16(blocks[i]), to: &trks)
                WOZ.append32(UInt32(tracks[i].count), to: &trks)
                block += blocks[i]
            } else {
                trks += [UInt8](repeating: 0, count: 8)
            }
        }
        for (track, n) in zip(tracks, blocks) {
            trks += track.bytes + [UInt8](repeating: 0, count: n * WOZ.blockSize - track.bytes.count)
        }
        chunk("TRKS", trks)
        if let meta { chunk("META", meta) }
        let crc = WOZ.crc32(out[12...])
        for i in 0 ..< 4 { out[8 + i] = UInt8(truncatingIfNeeded: crc >> (8 * i)) }
        return out
    }

    // MARK: bits ⇄ nibbles

    /// The nibbles the Disk II reads off a track of `count` bits going
    /// round, and each one's length in bits: its 8, and the 0s after it
    /// (2 after a self-sync FF).  The latch shifts bits in, a byte is done
    /// when bit 7 is set, and the next starts at the next 1 bit.  It reads
    /// one turn to fall into step, then one more turn is the track.  Empty:
    /// no byte in it.
    static func nibbles(bits: [UInt8], count: Int) -> (nibbles: [UInt8], lengths: [UInt8]) {
        guard count > 0 else { return ([], []) }
        @inline(__always) func bit(_ i: Int) -> UInt8 {
            let j = i % count
            return bits[j >> 3] >> (7 - j & 7) & 1
        }
        var latch: UInt8 = 0
        var i = 0
        /// The next byte from bit `i` on, and the bit it starts at; nil
        /// after two turns with none.
        func next() -> (nibble: UInt8, start: Int)? {
            let limit = i + 2 * count
            var start = i
            while i < limit {
                let b = bit(i)
                i += 1
                if latch == 0 {
                    guard b == 1 else { continue }
                    start = i - 1
                }
                latch = latch << 1 | b
                if latch & 0x80 != 0 {
                    defer { latch = 0 }
                    return (latch, start)
                }
            }
            return nil
        }
        // one turn to fall into step, then the byte boundaries repeat
        while i < count { guard next() != nil else { return ([], []) } }
        let turn = i
        var nibbles = [UInt8](), starts = [Int]()
        nibbles.reserveCapacity(count / 8)
        starts.reserveCapacity(count / 8)
        while i < turn + count, let n = next() {
            nibbles.append(n.nibble)
            starts.append(n.start)
        }
        guard let first = starts.first else { return ([], []) }
        let lengths = starts.indices.map { k in
            let next = k + 1 < starts.count ? starts[k + 1] : first + count
            return UInt8(max(8, min(255, next - starts[k])))
        }
        return (nibbles, lengths)
    }

    /// Nibbles as bits: each one's 8, then 0s to its length (`lengths`,
    /// 8 when nil): a self-sync FF is 10 long.
    static func bits(nibbles: [UInt8], lengths: [UInt8]? = nil) -> Track {
        var bytes = [UInt8](), acc: UInt32 = 0, n = 0, count = 0
        bytes.reserveCapacity(nibbles.count * 9 / 8 + 1)
        func put(_ value: UInt32, _ width: Int) {
            acc = acc << width | value
            n += width
            count += width
            while n >= 8 {
                n -= 8
                bytes.append(UInt8(truncatingIfNeeded: acc >> n))
            }
        }
        for (k, v) in nibbles.enumerated() {
            put(UInt32(v), 8)
            var zeros = Int(lengths?[k] ?? 8) - 8
            while zeros > 0 {
                put(0, min(zeros, 16))
                zeros -= 16
            }
        }
        if n > 0 { bytes.append(UInt8(truncatingIfNeeded: acc << (8 - n))) }
        return Track(bytes: bytes, count: count)
    }

    // MARK: helpers

    static func u16(_ d: [UInt8], _ i: Int) -> UInt16 { UInt16(d[i]) | UInt16(d[i + 1]) << 8 }
    static func u32(_ d: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(d, i)) | UInt32(u16(d, i + 2)) << 16 }

    static func append16(_ v: UInt16, to out: inout [UInt8]) {
        out += [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    static func append32(_ v: UInt32, to out: inout [UInt8]) {
        append16(UInt16(v & 0xFFFF), to: &out)
        append16(UInt16(v >> 16), to: &out)
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { n in
        (0 ..< 8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ c >> 1 : c >> 1 }
    }

    /// CRC-32 (zlib's), as the header has it.
    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        ~bytes.reduce(~UInt32(0)) { c, b in crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ c >> 8 }
    }
}
