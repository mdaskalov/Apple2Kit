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

## Natives and layers

A host that draws some of a program's graphics in its own way (a font, a
sprite at its own resolution, a layer of its own) and the rest as the
Apple's pixels needs the program's code to run as ever – memory and timing
the original's – while its drawing goes where the host wants it. Three
things in Emulator/Natives.swift, Emulator/Layers.swift and
Emulator/PageWrites.swift:

* **Natives** (`addNative(at:name:maxSteps:onJump:_:)`): a named native for the
  routine at an address, run where a JSR calls it – not where a branch, a
  JMP or an RTS gets there (the CPU's `callTraps` and `onCall`, after the
  JSR's pushes and 6 cycles). With `onJump: true` also where a JMP gets
  there (the CPU's `jumpTraps`, after the JMP's cycles): a tail call, a
  caller's last `JMP routine` in place of `JSR routine / RTS`. The stack
  then holds the caller's caller's return address, where the routine's
  RTS goes: `returnAddress` is that one, and `run` works as after a JSR.
  The routine's own JMPs back to its start fire it too, as a call inside
  it (it then draws where it draws). Off by default: a JMP to a routine's
  start isn't always a call. It gets a `NativeCall` (the machine, the
  registers and stack pointer at the entry, the return address, `depth`:
  the natives it runs inside) and decides what the call does:
  * `call.run()` runs the routine's own code as the CPU runs it, up to its
    RTS (the return address, the stack pointer 2 above the entry's): memory,
    registers and cycles the code's, the natives it calls run. It draws
    where it draws now: on layer 0, or on the target of the native it runs
    inside. It returns the cycles the code took, nil where it went astray
    (`maxSteps` instructions, a BRK, a jam: the CPU goes on from where it
    is). Once a call.
  * `call.run(into: target)` runs it drawing on its target (`DrawTarget`):
    a layer (`.layer(n)`, or just `run(into: 2)`; `.main` is layer 0) or
    `.discard` (nowhere). A native inside it draws there too, unless it
    names a target of its own. `drawsOnLayer` tells a native inside such
    a run.
  * Without `run` the code is left out: the call returns (RTS) with the
    registers as the native leaves them.
  * It returns the cycles the call takes after the JSR: `run`'s for the
    original's pace, fewer to run faster, 0 for none. What the code did by
    the clock in between (a click) keeps the cycle it had.

  Switched off by its name the routine runs as ever. At an address the
  first native switched on runs.
* **Layers** one byte at an address, as
  on the Apple – main memory's. Each byte of $2000‑$5FFF also has a
  layer number, the drawing that wrote it last (`layer(at:)`): 0 the
  code's own, *n* a native's run into `.layer(n)`. The code reads memory
  as ever, so it finds what the original finds, branches and cycles the
  original's; a write sets the byte's layer (the CPU watches $20‑$5F
  once a byte may be another layer's than 0; a Swift native's writes by
  `RAM` too). A plain write makes the byte layer 0's again.
  **Hidden layers** (`hiddenLayers`): in memory as any other, but the
  dots their code lit are the host's to draw (`hiddenDots(at:)`,
  `HiresScreen.hidden`). **Passed dots** (`passedDots(at:)`,
  `HiresScreen.passed`): a drawing over a byte owns only the dots its code
  clears or sets; those it passes through as they were (a sprite's mask
  lets them through) stay what they were – hidden dots hidden, and on a
  layer over 0 transparent in its group's image, the host's drawing and
  the layers under it showing there. A dot that is the same before and
  after is either, and the bytes don't tell, so the machine follows the
  bits (**bit flow**, BitFlow.swift): for each of A, X and Y the bits that
  are still a page byte's, in place, and which byte's. A load from a page
  byte starts them; `AND` keeps a bit of A where the operand has a 1 and
  one of the operand's (a page byte's) where A has a 1, `ORA` and `EOR`
  where the other has a 0 (a byte with itself: `AND`, `ORA` keep its bits,
  `EOR` clears them); transfers copy them; anything else that
  changes a register makes its bits the code's; a store into the byte
  they came from leaves them as passed through. The code runs once, as
  ever, memory, registers and cycles untouched. What isn't followed
  counts as the code's own drawing (opaque): a bit that goes through
  memory (the stack, a zero-page temporary), moves (a shift) or into
  another byte, an instruction a hook may take. It follows the engine's
  every merge (`(old AND keep) OR set`, in either order of the operands);
  it runs while a byte may be another layer's than 0 (`layersUsed`),
  except as the code draws a hidden layer's (its own dots, those it
  lights) or `.discard`'s. A host steps the machine with `step()` or
  `call()` for it, not `cpu.step`/`cpu.call`; a copy of the machine goes
  on with the bits its registers hold. A byte has one layer: the
  dots its layer passed through count as the layers' under the groups
  over 0 (with layer 0's group in the images), also those another layer
  over 0 drew before.
  `.discard`
  writes nothing, memory and layers stay as they were: the code reads
  back what it wrote (its own, or that of a `.discard` it runs inside)
  until it returns. `clearLayers(page2:)` makes a page's bytes layer 0's
  (the bytes stay); a copy of the machine has the layers, a restored
  state none.
* **Showing them** (`hiresScreen(page2:)`: a `HiresScreen` with its
  bytes' `layers`; `Screen.images(screen, groups:style:)`): the layers shown
  in groups (`[0 ... 5, 6 ... 9]`), each group an image to put over the
  ones before it, the host's own drawing in between. The bytes of the
  layers shown make one page (`HiresScreen.showing`: a byte of a layer not
  shown has no pixels); each byte's dots are in its layer's group's image,
  coloured as on that one page (a pixel next to a lit one on another layer
  is white), black too, the rest transparent; the group with layer 0 is the
  whole page, opaque. So the images over each other are that page. A
  hidden dot is black in it and transparent in the groups' images: the
  host's drawing in between shows there (a text in its own font under a
  sprite drawn over the text's pixels), and so is a dot its layer passed
  through (`HiresScreen.passed`): only the dots a sprite's code cleared or
  set cover the host's drawing.
* **Page writes** (`onPageWrite`): the address of every write to main
  memory's $2000‑$5FFF while set, whatever layer it is (not
  `.discard`'s): a host following what the code draws on the pages. The
  kit owns `cpu.onWrite` for it (watching $20‑$5F). Double hi‑res (aux
  memory) isn't followed and has no layers.

```swift
machine.addNative(at: drawShip.entry, name: "DRAW_SHIP") { call in
    call.run(into: 1) ?? 0                  // the ship on layer 1, over the page
}
machine.addNative(at: drawScore.entry, name: "DRAW_SCORE") { call in
    scoreText = readScore(call.cpu.mem)     // the host draws it
    return call.run(into: .discard) ?? 0    // the code runs, its pixels dropped
}
```

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
kind, an image), watched pages, the symbol file's text. `swift test
--filter PageWriteTests`: the writes to the pages told. `swift test --filter
NativeTests`: a native only where a JSR calls (not a branch back to the
routine's start), the code's memory, registers and cycles, drawing on a
layer (memory written, its bytes the layer's, the code's next write layer
0's; page writes told, a page's layers cleared), discarded (nothing
written, read back), the code left out, fewer cycles, natives inside
natives (on the outer's layer or their own, inside `.discard`), a copy
inside a drawing, switched off, taken out, code going astray; the pages'
layers (a copy's, cleared), `showing`, and `Screen.images`' groups as one
page.
