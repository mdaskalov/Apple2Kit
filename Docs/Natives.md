# A program's memory by name

For a host that runs a program on the machine and takes parts of it over in
Swift: a *native routine* runs where the CPU reaches a routine's entry
(`Apple2Machine.addHook`), does what the 6502 code does, and
returns like RTS. The machine runs it as a *hook* (below, *Hooks and
switches*). Such code needs the program's addresses. This part of the
package (`Sources/Apple2Kit/Natives`, no UI) keeps them in one place, by
name:

* a **symbol map**: the program's variables, tables and routines, each with
  its address;
* **memory by those names** for the Swift code (`RAM`);
* a **fingerprint** of a routine's code, so Swift only replaces the code it
  was written from;
* the names as a **symbol file** for AppleWin's and Mariani's debugger.

## The symbol map

A class with a symbol in each stored property:

```swift
final class Symbols: SharedSymbolMap {
    static let map = Symbols()

    let lives = Byte(0x4A)                  // one byte
    let shipX = Word(0x4B)                  // two, low byte first
    let scores = Table(0x0300)              // bytes indexed from the address
    let drawShip = Routine(0x6000)          // code at an entry point
    let sub6100 = Routine(0x6100, guess: true)
}
```

(`nonisolated final class` in a module whose default isolation is the main
actor.) A `SharedSymbolMap` is a map of which there is one, `Symbols.map`:
`Symbols.address(\.drawShip)` is $6000. A program's own kinds of symbol are
types of its own that conform to `Symbol`:

```swift
struct Sprite: Symbol {
    let address: Int
    let guess: Bool
}
```

**Names.** A symbol's name is its property's, in capitals: `shipX` is
SHIP_X, `drawShip2Flame` DRAW_SHIP2_FLAME, `sub6100` SUB_6100 (an address
at the end, four hex digits after a lower-case letter); a `guess` adds
`_Q`. `map.named` lists every symbol with its name in the order declared
(the map is looked through once, by reflection), `map.name(of: \.drawShip)`
is a routine's, and `map.name(Routine.self, at: 0x6000)` the name of what
is at an address.

## A program in several builds

A program may come in builds: versions, or the same code assembled for
other addresses. Each build has a map of its own, a class; what all of them
have at the same place is in a common parent (`SymbolMap`, of which
`SharedSymbolMap` is the kind with one instance):

```swift
class ProgramSymbols: SymbolMap, @unchecked Sendable {
    let lives = Byte(0x4A)                  // the same in every build
}

final class DiskSymbols: ProgramSymbols, @unchecked Sendable {
    let score = Byte(0x80)
}

final class TapeSymbols: ProgramSymbols, @unchecked Sendable {
    let score = Byte(0x84)
    let bonus = Byte(0x90)                  // only this build has it
}
```

The host uses the map of the build that is loaded: `cpu.withRAM(tape)`
sees `m.lives` and `m.score`, `tape.named` lists the parent's symbols and
its own, a symbol file is written from each. Code for what every build has
is written for the parent and runs on any of them:

```swift
func loseLife<Map: ProgramSymbols>(_ m: RAM<Map>) { m.lives &-= 1 }
```

Code for names that several builds have at places of their own is written
for a protocol the builds' classes conform to (`var score: Byte { get }`).
Either way the compiler makes a version of the code for each map it is
used with, the addresses folded in. A symbol that moves between two
versions of a build gets its address in the class's initialiser
(`init(_ version:)`, the property declared without a value).

## Fingerprints

A routine that Swift stands in for has its `code`: the address ranges of
its instructions – the variables between them left out – and the MD5 of
those bytes.

```swift
let drawShip = Routine(0x6000, code: 0x6000 ..< 0x6040, 0x6042 ..< 0x6080, md5: "16d1…")
```

`routine.matches(mem)` tells whether the 64K hold that code (nil: the
routine has no fingerprint). A host asks before it puts the Swift in, so a
modified or damaged copy of the program runs its own 6502 code there. To
get a new routine's MD5, give it its ranges with `md5: ""` and print
`routine.code!.digest(mem)`.

## Memory by name

`RAM<Map>` is the CPU's own 64K, not a copy – what the Swift writes is what
the 6502 code reads next – with every symbol of the map as a property:

```swift
cpu.withRAM(Symbols.map) { m in
    m.lives &-= 1                           // a Byte is a UInt8
    m.shipX = 0x0120                        // a Word is an Int
    m.scores[2] = m.lives                   // a Table is indexed from its address
    m[0x0400 + 40 * row] = 0xA0             // a computed address; they wrap at 64K
}
```

A program's own kinds read as it says:

```swift
extension RAM where Map == Symbols {
    subscript(dynamicMember s: KeyPath<Symbols, Sprite>) -> Int { address(s) }
}
```

A variable passed around is its key path: `m[axis]` for `axis = \.shipX`.

**Watched pages.** What the Swift writes to a page the CPU watches
(`CPU6502.watchedPages`) is told to its `onWrite`, with the byte as it was,
as the 6502 code's writes are: a host that follows the hi-res pages sees a
native routine's drawing too. (The pages watched are those watched when
`withRAM` is called.) `RAM(pointer, map: map)` is a memory image by name:
nothing follows what is written there.

**Speed.** In an optimised build `m.shipX` is a load of the address from
the map and a byte access: the accessors are `@inlinable` and inlined into
the code that uses them, the key path folded into the property's place in
the map's object. So a native routine written this way costs what the same
code on a bare pointer costs. A build without optimisation goes through the
key path at every access, some 50 times slower.

A native routine with these pieces (`CPU6502.Registers` has the registers
as a value, with the flags as the instructions set them):

```swift
let machine = apple.machine
let drawShip = Symbols.map.drawShip
if drawShip.matches(machine.cpu.mem) == true {
    machine.addHook(at: drawShip.entry, name: "DRAW_SHIP") { machine in
        machine.cpu.withRAM(Symbols.map) { m in
            m.lives &-= 1
        }
        machine.cpu.returnFromSubroutine()  // like RTS
        return true
    }
}
```

## Hooks and switches

`Apple2Machine` runs Swift where the CPU reaches an address
(Emulator/Hooks.swift):

* `addHook(at:name:_:)` – before the instruction there; it returns true
  when it handled it (set the CPU up to go on, PC and all: a routine in
  Swift returns with `cpu.returnFromSubroutine()`), false to let the
  instruction run.
* `addObserver(at:name:first:_:)` – looks before the hooks there, which
  then run as ever (a host following what the code does: where a drawing
  starts, where it returns).
* `removeHook(id)` takes either out.
* `switchedOff` – the names of the hooks switched off: they stay put in,
  but don't run, and the CPU doesn't stop at their address for them. From
  the next instruction on. A native that leaves memory (and the registers
  its callers use) as the code does can be switched at any instruction.
* `isHooked(address)` – a hook switched on is there.

The hooks own the CPU's trap bits (`CPU6502.traps`): a bit is set while a
hook switched on is at its address (or the mouse card's firmware), so the
CPU stops nowhere else. At an address the observers run first, in the
order put in (`first` before them), then the hooks, until one handles the
instruction. A hook taken out by another during the same stop doesn't run.
`copy()` copies the hooks and their switches.

**The host.** A hook gets the machine; a host keeping state of its own
with it sets itself as `host`, and its hooks find it there
(`machine.host as? MyHost`). The machine doesn't keep it (the host keeps
the machine): `host` is unowned, not weak – a weak reference would move
the host's reference counts to a side table and make every retain of it
slower, which a host whose callbacks run millions of times a second
notices. A copy has no host: the host's copy sets itself.

`onTrap` stays for traps a host sets itself in `cpu.traps`, asked where no
hook took the stop.

## Symbol files

`SymbolFile` writes the names in AppleWin's format (a line a symbol, `ADDR
NAME`, sorted by name; `;` starts a comment; CRLF):

```swift
try SymbolFile(Symbols.map, comments: ["My program"]).write(to: url)

var file = SymbolFile(comments: ["My program, the tape build"])
file.add(tape.named)                                // a build's map
file.add(LoaderSymbols.named, prefix: "L_")         // another map's, their names after a prefix
```

In AppleWin's debugger (and Mariani's) `SYMUSER LOAD "name"` reads the file
from the emulator's program folder; the debugger then takes a name wherever
it takes an address and shows the names in its disassembly.

## Tests

`swift test --filter HookTests`: a hook in place of code and taken out,
observers and the order at an address, one taken out by another, switches
(the trap cleared, the code run), copies and their host, the mouse card's
traps staying. `swift test --filter SymbolTests`: addresses, the names (a build's with
its parent's), fingerprints (a variable between the instructions changed,
an instruction changed, a build's own code), memory by name (wrapping at
64K, two builds' maps, code for their parent on both, a program's own
kind, an image), watched pages, the symbol file's text.
