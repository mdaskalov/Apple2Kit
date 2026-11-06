import Foundation

/// A 5.25" disk as the Disk II reads it: 35 tracks of nibbles (the bytes on
/// the disk's surface, high bit set), made from an image file.
///
/// * `.dsk`, `.do`, `.po`: 140K of sector data (35 tracks × 16 sectors × 256
///   bytes), in DOS 3.3 order (`.do`, `.dsk` usually) or ProDOS order (`.po`,
///   some `.dsk`: `SectorOrder.detect`).  Each track is nibblized as DOS 3.3
///   formats it: 16 sectors, 6-and-2 encoded, volume 254.
/// * `.nib`: 35 tracks of 6656 nibbles as they are on the disk, taken as they
///   are (copy protection that lives in the nibbles survives).
///
/// What the Disk II writes goes into the nibble tracks; `fileData()` decodes
/// them back into the image's own format (Docs/DiskII.md).
public nonisolated struct DiskImage {
    static let tracks = 35
    static let sectors = 16
    static let sectorSize = 256
    static let trackSize = sectors * sectorSize            // 4096
    static let sectorImageSize = tracks * trackSize        // 143360
    static let nibblesPerTrack = 6656                      // $1A00, a .nib track
    static let nibImageSize = tracks * nibblesPerTrack     // 232960
    static let volume: UInt8 = 254

    public enum Format: String, Sendable {
        case dos = "DOS order"
        case prodos = "ProDOS order"
        case nib = "Nibbles"
    }

    public enum ImageError: LocalizedError {
        case badSize(String, Int)

        public var errorDescription: String? {
            switch self {
            case .badSize(let name, let size):
                "\(name) is \(size) bytes: not a 140K .dsk/.do/.po (143360) or a .nib (232960) image."
            }
        }
    }

    let name: String
    let format: Format
    /// The nibbles of each track.
    private(set) var nibbles: [[UInt8]]
    /// Tracks written since the image was made or saved.
    private(set) var dirtyTracks = Set<Int>()
    /// The sector data the image was made from (empty for `.nib`): sectors
    /// that can't be decoded from a written track keep theirs.
    private var sectorData: [UInt8]

    public init(name: String, data: [UInt8]) throws {
        self.name = name
        let ext = (name as NSString).pathExtension.lowercased()
        switch data.count {
        case DiskImage.sectorImageSize:
            format = ext == "po" ? .prodos : ext == "do" ? .dos : SectorOrder.detect(data)
            sectorData = data
            let order = format == .prodos ? SectorOrder.prodos : SectorOrder.dos
            nibbles = (0 ..< DiskImage.tracks).map { DiskImage.nibblize(track: $0, of: data, order: order) }
        case DiskImage.nibImageSize:
            format = .nib
            sectorData = []
            nibbles = (0 ..< DiskImage.tracks).map {
                Array(data[$0 * DiskImage.nibblesPerTrack ..< ($0 + 1) * DiskImage.nibblesPerTrack])
            }
        default:
            throw ImageError.badSize(name, data.count)
        }
    }

    public var isModified: Bool { !dirtyTracks.isEmpty }

    /// Writes `value` at nibble `position` of `track` (the Disk II writing).
    mutating func write(_ value: UInt8, track: Int, position: Int) {
        nibbles[track][position] = value
        dirtyTracks.insert(track)
    }

    /// The image in its file's format, with what was written: the nibble
    /// tracks as they are for `.nib`, else the sectors decoded from them.
    public mutating func fileData() -> [UInt8] {
        defer { dirtyTracks = [] }
        if format == .nib { return nibbles.flatMap { $0 } }
        let order = format == .prodos ? SectorOrder.prodos : SectorOrder.dos
        for track in dirtyTracks.sorted() {
            for (physical, bytes) in DiskImage.denibblize(nibbles[track], track: track) {
                let offset = track * DiskImage.trackSize + Int(order.imageSector[physical]) * DiskImage.sectorSize
                sectorData.replaceSubrange(offset ..< offset + DiskImage.sectorSize, with: bytes)
            }
        }
        return sectorData
    }

    // MARK: 6-and-2 encoding

    /// The 64 disk bytes (nibbles) a 6-bit value is written as.
    static let writeTable: [UInt8] = [
        0x96, 0x97, 0x9A, 0x9B, 0x9D, 0x9E, 0x9F, 0xA6, 0xA7, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, 0xB2, 0xB3,
        0xB4, 0xB5, 0xB6, 0xB7, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xCB, 0xCD, 0xCE, 0xCF, 0xD3,
        0xD6, 0xD7, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE5, 0xE6, 0xE7, 0xE9, 0xEA, 0xEB, 0xEC,
        0xED, 0xEE, 0xEF, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
    ]

    /// Disk byte → 6-bit value; $FF: not a data nibble.
    static let readTable: [UInt8] = {
        var t = [UInt8](repeating: 0xFF, count: 256)
        for (value, nibble) in writeTable.enumerated() { t[Int(nibble)] = UInt8(value) }
        return t
    }()

    /// Gaps in self-sync bytes ($FF): before the first sector, between an
    /// address field and its data field, after each data field.  48 + 16 ×
    /// (14 + 6 + 349 + 44) = 6656, a whole track.
    static let gap1 = 48, gap2 = 6, gap3 = 44

    /// The bits of a byte's two low bits swapped, as the 6-and-2 encoding keeps them.
    @inline(__always) private static func swapLow2(_ b: UInt8) -> UInt8 {
        (b & 1) << 1 | (b & 2) >> 1
    }

    /// 4-and-4 encoding (address fields): odd bits, then even bits, each with $AA.
    private static func append44(_ v: UInt8, to out: inout [UInt8]) {
        out.append(v >> 1 | 0xAA)
        out.append(v | 0xAA)
    }

    /// One track as DOS 3.3 formats and writes it: physical sectors 0-15 in
    /// order around the track, sector `p` holding the image's sector
    /// `order.imageSector[p]`.
    static func nibblize(track: Int, of data: [UInt8], order: SectorOrder) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(nibblesPerTrack)
        out += repeatElement(0xFF, count: gap1)
        let t = UInt8(track)
        for physical in 0 ..< sectors {
            let s = UInt8(physical)
            out += [0xD5, 0xAA, 0x96]
            append44(volume, to: &out)
            append44(t, to: &out)
            append44(s, to: &out)
            append44(volume ^ t ^ s, to: &out)
            out += [0xDE, 0xAA, 0xEB]
            out += repeatElement(0xFF, count: gap2)
            out += [0xD5, 0xAA, 0xAD]
            let offset = track * trackSize + Int(order.imageSector[physical]) * sectorSize
            out += encode62(data[offset ..< offset + sectorSize])
            out += [0xDE, 0xAA, 0xEB]
            out += repeatElement(0xFF, count: gap3)
        }
        return out
    }

    /// A sector's 256 bytes as 343 nibbles: 86 values of the bytes' low two
    /// bits, then 256 of their high six, each written EOR the one before, and
    /// the last value as the checksum.
    static func encode62(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        let b = Array(bytes)
        var values = [UInt8](repeating: 0, count: 342)
        for i in 0 ..< 86 {
            var v = swapLow2(b[i]) | swapLow2(b[i + 86]) << 2
            if i + 172 < 256 { v |= swapLow2(b[i + 172]) << 4 }
            values[i] = v
        }
        for i in 0 ..< 256 { values[86 + i] = b[i] >> 2 }
        var out = [UInt8]()
        out.reserveCapacity(343)
        var previous: UInt8 = 0
        for v in values {
            out.append(writeTable[Int(v ^ previous)])
            previous = v
        }
        out.append(writeTable[Int(previous)])
        return out
    }

    /// The 256 bytes of 343 nibbles; nil if one isn't a data nibble or the
    /// checksum is wrong.
    static func decode62(_ nibbles: ArraySlice<UInt8>) -> [UInt8]? {
        guard nibbles.count == 343 else { return nil }
        var values = [UInt8](repeating: 0, count: 342)
        var previous: UInt8 = 0
        for (i, n) in nibbles.prefix(342).enumerated() {
            let x = readTable[Int(n)]
            guard x != 0xFF else { return nil }
            previous ^= x
            values[i] = previous
        }
        guard readTable[Int(nibbles.last!)] == previous else { return nil }
        var out = [UInt8](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            let low = values[i % 86] >> (2 * (i / 86)) & 3
            out[i] = values[86 + i] << 2 | swapLow2(low)
        }
        return out
    }

    /// The sectors of a nibble track: each address field (D5 AA 96) of this
    /// track with a good checksum, and the data field (D5 AA AD) after it,
    /// by physical sector.  The track is read twice round, so a field across
    /// its end is found too.
    static func denibblize(_ track: [UInt8], track number: Int) -> [Int: [UInt8]] {
        let n = track.count
        let ring = track + track
        func decode44(_ i: Int) -> UInt8 { (ring[i] << 1 | 1) & ring[i + 1] }
        var found: [Int: [UInt8]] = [:]
        var i = 0
        while i < n {
            defer { i += 1 }
            guard ring[i] == 0xD5, ring[i + 1] == 0xAA, ring[i + 2] == 0x96 else { continue }
            let (v, t, s, c) = (decode44(i + 3), decode44(i + 5), decode44(i + 7), decode44(i + 9))
            guard v ^ t ^ s == c, Int(t) == number, s < 16 else { continue }
            // the data field: its prologue within the next 64 nibbles
            var j = i + 11
            while j < i + 75, !(ring[j] == 0xD5 && ring[j + 1] == 0xAA && ring[j + 2] == 0xAD) { j += 1 }
            guard j < i + 75, j + 3 + 343 <= ring.count,
                  let bytes = decode62(ring[j + 3 ..< j + 3 + 343]) else { continue }
            if found[Int(s)] == nil { found[Int(s)] = bytes }
        }
        return found
    }
}

/// Where the sectors of a track are in a 140K image.
nonisolated struct SectorOrder {
    /// By physical sector (the number in its address field): the image's
    /// sector, the 256-byte slot of the track in the file.
    let imageSector: [UInt8]

    /// DOS 3.3 order (.do, most .dsk): file sector = DOS logical sector.
    static let dos = SectorOrder(imageSector: [0x0, 0x7, 0xE, 0x6, 0xD, 0x5, 0xC, 0x4, 0xB, 0x3, 0xA, 0x2, 0x9, 0x1, 0x8, 0xF])
    /// ProDOS order (.po): file sectors 2k, 2k+1 = block k of the track.
    static let prodos = SectorOrder(imageSector: [0x0, 0x8, 0x1, 0x9, 0x2, 0xA, 0x3, 0xB, 0x4, 0xC, 0x5, 0xD, 0x6, 0xE, 0x7, 0xF])

    /// The order of a `.dsk`: ProDOS when its block 2 is a ProDOS volume
    /// directory read in ProDOS order and isn't in DOS order, and it has no
    /// DOS 3.3 VTOC; DOS otherwise (Docs/DiskII.md).
    static func detect(_ data: [UInt8]) -> DiskImage.Format {
        if hasDOSCatalog(data) { return .dos }
        if isVolumeDirectory(data, block: 2, order: .prodos) && !isVolumeDirectory(data, block: 2, order: .dos) {
            return .prodos
        }
        return .dos
    }

    /// A DOS 3.3 VTOC at track 17 sector 0: catalog track 1-34, sector 0-15,
    /// 35 tracks of 16 sectors of 256 bytes.
    static func hasDOSCatalog(_ d: [UInt8]) -> Bool {
        let v = 17 * DiskImage.trackSize
        return (1 ... 34).contains(d[v + 1]) && d[v + 2] < 16 && d[v + 0x34] == 35 && d[v + 0x35] == 16
            && d[v + 0x36] == 0 && d[v + 0x37] == 1
    }

    /// Block `block`'s 512 bytes of a 140K image in `order`: ProDOS block k
    /// of a track is physical sectors (2k, 2k+1) under the ProDOS skew.
    static func block(_ d: [UInt8], _ block: Int, order: SectorOrder) -> [UInt8] {
        let track = block / 8, k = block % 8
        // physical sectors of ProDOS's sectors 2k and 2k+1
        let prodosToPhysical = [0x0, 0x2, 0x4, 0x6, 0x8, 0xA, 0xC, 0xE, 0x1, 0x3, 0x5, 0x7, 0x9, 0xB, 0xD, 0xF]
        return [2 * k, 2 * k + 1].flatMap { s -> [UInt8] in
            let offset = track * DiskImage.trackSize + Int(order.imageSector[prodosToPhysical[s]]) * DiskImage.sectorSize
            return Array(d[offset ..< offset + DiskImage.sectorSize])
        }
    }

    /// A ProDOS volume directory key block: no previous block, storage type
    /// $F with a name, entries of $27 bytes, $0D a block.
    static func isVolumeDirectory(_ d: [UInt8], block n: Int, order: SectorOrder) -> Bool {
        let b = block(d, n, order: order)
        return b[0] == 0 && b[1] == 0 && b[4] >> 4 == 0xF && b[4] & 0xF > 0 && b[0x23] == 0x27 && b[0x24] == 0x0D
    }
}
