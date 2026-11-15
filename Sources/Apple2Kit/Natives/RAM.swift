import MOS6502

/// Memory as Swift code that stands in for 6502 code sees it (a native
/// routine, run where the CPU reaches the routine's entry:
/// `CPU6502.traps`): the CPU's own 64K, not a copy – what the Swift writes
/// is what the 6502 code reads next –, with every symbol of a map by name:
///
///     cpu.withRAM(Symbols.map) { m in
///         m.shipX = m.startX[m.player]
///         m.lives &-= 1
///     }
///
/// A `Byte` reads as UInt8, a `Word` as Int, a `Table` as `Bytes` (indexed
/// from its address).  Addresses wrap at 64K like the 6502's.  A program's
/// own kinds of symbol read as it says, by a subscript of its own:
///
///     extension RAM where Map == Symbols {
///         subscript(dynamicMember s: KeyPath<Symbols, Sprite>) -> Int { address(s) }
///     }
///
/// `m.shipX` compiles to a load of the address from the map and a byte
/// access: the accessors are inlined into the code that uses them, which
/// takes an optimised build of that code.
///
/// Valid only while the memory it was made on is: within `withRAM`'s call.
@dynamicMemberLookup
public nonisolated struct RAM<Map: SymbolMap> {
    /// The 64K.
    public let bytes: UnsafeMutablePointer<UInt8>
    /// The map: where the symbols are (unowned: it outlives the call).
    public unowned(unsafe) let map: Map
    /// The CPU whose memory it is and its watched pages, a flag a page
    /// (`CPU6502.watchedPages`, as they are when the call starts); nil: a
    /// memory image, nothing follows what is written there.  Unowned: the
    /// CPU outlives the call.
    @usableFromInline unowned(unsafe) let cpu: CPU6502?
    @usableFromInline let watched: UnsafePointer<Bool>?

    /// The 64K at `bytes`, a memory image, by the names of `map`.
    @inlinable
    public init(_ bytes: UnsafeMutablePointer<UInt8>, map: Map) {
        self.bytes = bytes
        self.map = map
        cpu = nil
        watched = nil
    }

    /// The memory of `cpu`, at `bytes`, with its watched pages' flags at `watched`.
    @inlinable
    init(_ bytes: UnsafeMutablePointer<UInt8>, map: Map, cpu: CPU6502, watched: UnsafePointer<Bool>) {
        self.bytes = bytes
        self.map = map
        self.cpu = cpu
        self.watched = watched
    }

    /// The byte at a computed address (a pointer's target, a table's entry).
    /// One written to a page the CPU watches (`CPU6502.watchedPages`) is
    /// told to its `onWrite`, as the 6502 code's writes are.
    @inlinable @inline(__always)
    public subscript(_ a: Int) -> UInt8 {
        get { bytes[a & 0xFFFF] }
        nonmutating set {
            let a = a & 0xFFFF
            guard let watched, watched[a >> 8] else {
                bytes[a] = newValue
                return
            }
            let old = bytes[a]
            bytes[a] = newValue
            cpu.unsafelyUnwrapped.onWrite(UInt16(a), old, newValue)
        }
    }

    /// The 16-bit value at `a`, low byte first.
    @inlinable @inline(__always)
    public func word(_ a: Int) -> Int { Int(self[a]) | Int(self[a + 1]) << 8 }

    @inlinable @inline(__always)
    public func setWord(_ a: Int, _ v: Int) {
        self[a] = UInt8(v & 0xFF)
        self[a + 1] = UInt8(v >> 8 & 0xFF)
    }

    /// Where a symbol is.
    @inlinable @inline(__always)
    public func address<S: Symbol>(_ s: KeyPath<Map, S>) -> Int {
        map[keyPath: s].address
    }

    @inlinable @inline(__always)
    public subscript(dynamicMember s: KeyPath<Map, Byte>) -> UInt8 {
        get { self[address(s)] }
        nonmutating set { self[address(s)] = newValue }
    }

    /// A variable passed by its symbol: `m[axis]` for `axis = \.shipX`.
    @inlinable @inline(__always)
    public subscript(_ s: KeyPath<Map, Byte>) -> UInt8 {
        get { self[address(s)] }
        nonmutating set { self[address(s)] = newValue }
    }

    @inlinable @inline(__always)
    public subscript(dynamicMember s: KeyPath<Map, Word>) -> Int {
        get { word(address(s)) }
        nonmutating set { setWord(address(s), newValue) }
    }

    @inlinable @inline(__always)
    public subscript(dynamicMember s: KeyPath<Map, Table>) -> Bytes<Map> {
        Bytes(ram: self, address: address(s))
    }
}

/// A table in memory, indexed from its address.
public nonisolated struct Bytes<Map: SymbolMap> {
    public let ram: RAM<Map>
    public let address: Int

    @inlinable @inline(__always)
    public init(ram: RAM<Map>, address: Int) {
        self.ram = ram
        self.address = address
    }

    @inlinable @inline(__always)
    public subscript(_ i: Int) -> UInt8 {
        get { ram[address + i] }
        nonmutating set { ram[address + i] = newValue }
    }

    @inlinable @inline(__always)
    public subscript(_ i: UInt8) -> UInt8 {
        get { ram[address + Int(i)] }
        nonmutating set { ram[address + Int(i)] = newValue }
    }

    /// The 16-bit entry at byte `i`, low byte first.
    @inlinable @inline(__always)
    public func word(_ i: Int) -> Int { ram.word(address + i) }
}

public nonisolated extension CPU6502 {
    /// Runs `body` on the CPU's memory by the names of `map` (`RAM`).  What
    /// it writes to a watched page is told to `onWrite`, as the 6502 code's
    /// writes are.
    @inlinable
    func withRAM<Map: SymbolMap, R>(_ map: Map, _ body: (RAM<Map>) throws -> R) rethrows -> R {
        try watchedPages.withUnsafeBufferPointer { watched in
            try mem.withUnsafeMutableBufferPointer { bytes in
                try body(RAM(bytes.baseAddress!, map: map, cpu: self, watched: watched.baseAddress!))
            }
        }
    }
}
