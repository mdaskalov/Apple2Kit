import Foundation

/// A symbol file for the debugger of AppleWin (and of Mariani, AppleWin on
/// the Mac): a line a symbol, its address in hex and its name, sorted by
/// name; a line starting with `;` is a comment; CRLF line ends.  The
/// debugger loads it (`SYMUSER LOAD "name"`) and then takes a name wherever
/// it takes an address, and shows the names in its disassembly.
///
///     try SymbolFile(Symbols.map, comments: ["My program"]).write(to: url)
public nonisolated struct SymbolFile {
    /// The comment lines at the top.
    public var comments: [String]
    /// The names with their addresses, in the order added.
    public private(set) var symbols: [(name: String, address: Int)] = []

    public init(comments: [String] = []) {
        self.comments = comments
    }

    /// The symbols of `map`.
    public init(_ map: some SymbolMap, comments: [String] = []) {
        self.init(comments: comments)
        add(map.named)
    }

    /// Adds `symbols` (a map's `named`), each name after `prefix`.
    public mutating func add(_ symbols: [NamedSymbol], prefix: String = "") {
        self.symbols += symbols.map { (prefix + $0.name, $0.symbol.address) }
    }

    /// The file's text: the comments, an empty line, the symbols by name.
    /// An address has four hex digits; one in the zero page has no leading
    /// zeros and is right-aligned to the others.
    public var text: String {
        let lines = symbols.sorted { $0.name < $1.name }
            .map { String(format: $0.address < 0x100 ? "%4X %@" : "%04X %@", $0.address, $0.name) }
        return (comments.map { "; " + $0 } + (comments.isEmpty ? [] : [""]) + lines).joined(separator: "\r\n") + "\r\n"
    }

    public func write(to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
