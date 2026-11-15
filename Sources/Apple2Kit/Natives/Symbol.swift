import CryptoKit
import Foundation

/// A named place in a program's memory.  Its name is its property's in a
/// symbol map (`SymbolMap`), in capitals in a symbol file: `shipX` is
/// SHIP_X.
public nonisolated protocol Symbol: Sendable {
    var address: Int { get }
    /// The name is a guess (`_Q` in a symbol file).
    var guess: Bool { get }
    init(address: Int, guess: Bool)
}

public nonisolated extension Symbol {
    init(_ address: Int, guess: Bool = false) {
        self.init(address: address, guess: guess)
    }
}

/// One byte: a variable or a constant.
public nonisolated struct Byte: Symbol {
    public let address: Int
    public let guess: Bool

    public init(address: Int, guess: Bool) {
        self.address = address
        self.guess = guess
    }
}

/// Two bytes, low byte first: a pointer or a vector.
public nonisolated struct Word: Symbol {
    public let address: Int
    public let guess: Bool

    public init(address: Int, guess: Bool) {
        self.address = address
        self.guess = guess
    }
}

/// Bytes indexed from the address: an array.
public nonisolated struct Table: Symbol {
    public let address: Int
    public let guess: Bool

    public init(address: Int, guess: Bool) {
        self.address = address
        self.guess = guess
    }
}

/// Code at an entry point.  A routine that Swift code stands in for (a
/// native routine) has its `code`: where its instructions are, the variables
/// between them left out, and the MD5 of those bytes – its fingerprint.  A
/// host checks it (`matches`) before it puts the Swift in, so that a native
/// only ever replaces the exact code it was ported from.
public nonisolated struct Routine: Symbol {
    public let address: Int
    public let guess: Bool
    /// The fingerprint of its code; nil: its code isn't checked.
    public let code: Code?

    public init(address: Int, guess: Bool) {
        self.init(address: address, guess: guess, code: nil)
    }

    public init(address: Int, guess: Bool = false, code: Code?) {
        self.address = address
        self.guess = guess
        self.code = code
    }

    /// At `entry`, with its code in `code`, the ranges of its instructions.
    public init(_ entry: Int, code: Range<Int>..., md5: String) {
        self.init(address: entry, code: Code(ranges: code, md5: md5))
    }

    /// Its entry point.
    public var entry: UInt16 { UInt16(address) }

    /// Whether `mem` (the 64K as the code runs in them) holds the routine's
    /// code; nil: it has no fingerprint.
    public func matches(_ mem: [UInt8]) -> Bool? {
        code.map { $0.matches(mem) }
    }
}

/// A routine's code: the address ranges of its instructions and the MD5 of
/// their bytes.
public nonisolated struct Code: Sendable {
    public let ranges: [Range<Int>]
    /// The MD5 of the ranges' bytes, in lower-case hex; empty: not known yet
    /// (`digest` tells it).
    public let md5: String

    public init(ranges: [Range<Int>], md5: String) {
        self.ranges = ranges
        self.md5 = md5
    }

    /// The MD5 of these ranges of `mem`.
    public func digest(_ mem: [UInt8]) -> String {
        Insecure.MD5.hash(data: ranges.flatMap { mem[$0] }).map { String(format: "%02x", $0) }.joined()
    }

    public func matches(_ mem: [UInt8]) -> Bool { digest(mem) == md5 }
}
