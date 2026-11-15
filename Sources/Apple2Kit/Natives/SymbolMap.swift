import Foundation

/// A program's memory by name: a class with a symbol in each stored
/// property – its variables, tables and routines, each with its address and,
/// for a routine that Swift code stands in for, the fingerprint of its code
/// (`Routine`):
///
///     final class Symbols: SharedSymbolMap {
///         static let map = Symbols()
///
///         let lives = Byte(0x4A)
///         /// Where the ship is, in pixels.
///         let shipX = Word(0x4B)
///         let scores = Table(0x0300)
///         let drawShip = Routine(0x6000, code: 0x6000 ..< 0x6080, md5: "…")
///     }
///
/// The one place for the program's addresses.  Native routines use them by
/// name (`RAM`: `m.lives`), a host finds its routines by them
/// (`Symbols.address(\.drawShip)`), and a debugger's symbol file is written
/// from them (`SymbolFile`): a name is the same in Swift and in the
/// debugger.  A program's own kinds of symbol (a sprite, a string) are
/// types of its own that conform to `Symbol`.
///
/// A program that comes in several builds – versions, the same code
/// assembled for other addresses – has a map for each: classes with a
/// common parent for what all of them have at the same place, the one of
/// the build that is loaded used (`cpu.withRAM(map)`).  A symbol of the
/// parent is every map's, at a fixed place in the object, so code written
/// for the parent's symbols runs on any of them at full speed.
///
/// In a module whose default isolation is the main actor the class is
/// `nonisolated`.
public nonisolated protocol SymbolMap: AnyObject, Sendable {}

/// A symbol with its name in a map (`SymbolMap.named`).
public typealias NamedSymbol = (name: String, symbol: any Symbol)

public nonisolated extension SymbolMap {
    /// Where a symbol is.
    @inlinable @inline(__always)
    func address<S: Symbol>(_ s: KeyPath<Self, S>) -> Int {
        self[keyPath: s].address
    }

    /// Every symbol with its name, a parent's first, in the order declared:
    /// `shipX` is SHIP_X, `drawShip2Flame` DRAW_SHIP2_FLAME, `subDA44`
    /// SUB_DA44 (an address at the end, after a lower-case letter); a guess
    /// ends in `_Q`.  The map is looked through once.
    var named: [NamedSymbol] { NamedSymbols.shared.of(self).named }

    /// The name of a routine (of two at the same place, the first declared).
    func name(of routine: KeyPath<Self, Routine>) -> String {
        NamedSymbols.shared.of(self).routines[self[keyPath: routine].address] ?? "?"
    }

    /// The name of the `kind` of symbol (a routine, a table…) at `address`.
    func name<S: Symbol>(_ kind: S.Type, at address: Int) -> String? {
        named.first { $0.symbol is S && $0.symbol.address == address }?.name
    }
}

/// A map of which there is one, for a program in one build: `Symbols.map`,
/// and its symbols by the type alone, `Symbols.address(\.drawShip)`.
public nonisolated protocol SharedSymbolMap: SymbolMap {
    /// The map, made once.
    static var map: Self { get }
}

public nonisolated extension SharedSymbolMap {
    /// Where a symbol is.
    @inlinable @inline(__always)
    static func address<S: Symbol>(_ s: KeyPath<Self, S>) -> Int {
        map[keyPath: s].address
    }

    /// Every symbol with its name (`SymbolMap.named`).
    static var named: [NamedSymbol] { map.named }

    /// The name of a routine.
    static func name(of routine: KeyPath<Self, Routine>) -> String {
        map.name(of: routine)
    }

    /// The name of the `kind` of symbol at `address`.
    static func name<S: Symbol>(_ kind: S.Type, at address: Int) -> String? {
        map.name(kind, at: address)
    }
}

/// The maps' symbols with their names (`SymbolMap.named`), each map looked
/// through once: its stored properties that are symbols, its parents' first;
/// and its routines' names by where they are (`SymbolMap.name(of:)`).  The
/// maps are kept: there are few, and they live as long as the program.
private nonisolated final class NamedSymbols: @unchecked Sendable {
    typealias Names = (named: [NamedSymbol], routines: [Int: String])

    static let shared = NamedSymbols()
    private let lock = NSLock()
    private var maps: [ObjectIdentifier: (map: AnyObject, names: Names)] = [:]

    func of(_ map: some SymbolMap) -> Names {
        let id = ObjectIdentifier(map)
        if let names = lock.withLock({ maps[id]?.names }) { return names }
        var mirrors: [Mirror] = []
        var mirror: Mirror? = Mirror(reflecting: map)
        while let m = mirror {
            mirrors.insert(m, at: 0)
            mirror = m.superclassMirror
        }
        let named: [NamedSymbol] = mirrors.flatMap(\.children).compactMap { child in
            guard let label = child.label, let symbol = child.value as? any Symbol else { return nil }
            return (symbolName(label, guess: symbol.guess), symbol)
        }
        var routines: [Int: String] = [:]
        for (name, symbol) in named where symbol is Routine && routines[symbol.address] == nil {
            routines[symbol.address] = name
        }
        let names = (named, routines)
        lock.withLock { maps[id] = (map, names) }
        return names
    }
}

/// A property's name as a symbol's: in capitals, an underscore where a word
/// starts (`shipX` SHIP_X, `drawShip2Flame` DRAW_SHIP2_FLAME) and before an
/// address at the end, four hex digits after a lower-case letter (`subDA44`
/// SUB_DA44); `_Q` after a guess.
nonisolated func symbolName(_ property: String, guess: Bool = false) -> String {
    let c = Array(property)
    var end = c.count
    if c.count > 4, c[(c.count - 4)...].allSatisfy({ $0.isHexDigit && !$0.isLowercase }), c[c.count - 5].isLowercase {
        end = c.count - 4
    }
    var name = ""
    for i in 0 ..< end {
        if i > 0, c[i].isUppercase,
           c[i - 1].isLowercase || c[i - 1].isNumber || (c[i - 1].isUppercase && i + 1 < end && c[i + 1].isLowercase) {
            name += "_"
        }
        name += c[i].uppercased()
    }
    if end < c.count { name += "_" + String(c[end...]) }
    return guess ? name + "_Q" : name
}
