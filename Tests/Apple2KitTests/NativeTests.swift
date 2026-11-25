import CoreGraphics
import Foundation
import MOS6502
import Testing
@testable import Apple2Kit

/// Natives (`addNative`) on a machine without ROMs: where a JSR calls a
/// routine, the native decides what the call does.
@Suite struct NativeTests {
    /// $0340: `JSR $0300 / RTS`;
    /// $0300: `LDA #$AA / STA $2000 / JSR $0310 / LDX #$07 / RTS`;
    /// $0310: `LDA $2001 / ORA #$55 / STA $2001 / INC $10 / LDY #$03 / RTS`
    /// (23 cycles), drawing over what $2001 holds ($0A in memory);
    /// $0320: `DEX / BNE $0320 / RTS`, branching back to its own start;
    /// $0330: `LDX #$03 / JSR $0320 / RTS`.
    private func machine() -> Apple2Machine {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        m.cpu.mem.replaceSubrange(0x0340 ..< 0x0344, with: [0x20, 0x00, 0x03, 0x60])
        m.cpu.mem.replaceSubrange(0x0300 ..< 0x030B, with: [0xA9, 0xAA, 0x8D, 0x00, 0x20, 0x20, 0x10, 0x03, 0xA2, 0x07, 0x60])
        m.cpu.mem.replaceSubrange(0x0310 ..< 0x031D, with: [0xAD, 0x01, 0x20, 0x09, 0x55, 0x8D, 0x01, 0x20,
                                                            0xE6, 0x10, 0xA0, 0x03, 0x60])
        m.cpu.mem.replaceSubrange(0x0320 ..< 0x0324, with: [0xCA, 0xD0, 0xFD, 0x60])
        m.cpu.mem.replaceSubrange(0x0330 ..< 0x0336, with: [0xA2, 0x03, 0x20, 0x20, 0x03, 0x60])
        m.cpu.mem[0x2001] = 0x0A
        return m
    }

    private func run(_ m: Apple2Machine, _ address: UInt16 = 0x0340) throws {
        m.cpu.sp = 0xFF
        try m.cpu.call(address)
    }

    /// The cycles of $0340 without natives.
    private func plainCycles() throws -> UInt64 {
        let m = machine()
        try run(m)
        return m.cpu.cycles
    }

    @Test func onlyWhereAJSRCalls() throws {
        let m = machine()
        var calls = 0
        m.addNative(at: 0x0320) { call in
            calls += 1
            return call.run() ?? 0
        }
        #expect(m.cpu.callTraps[0x0320] && !m.cpu.traps[0x0320])
        try run(m, 0x0330)
        #expect(calls == 1 && m.cpu.x == 0)
    }

    @Test func runsTheCode() throws {
        let m = machine()
        var entryA: UInt8 = 0
        m.addNative(at: 0x0310) { call in
            entryA = call.entry.a
            #expect(call.returnAddress == 0x0308 && call.depth == 0)
            let cycles = call.run()
            #expect(cycles == 23)
            return cycles ?? 0
        }
        try run(m)
        #expect(entryA == 0xAA && m.cpu.mem[0x2001] == 0x5F)
        #expect(m.cpu.mem[0x10] == 1 && m.cpu.y == 3 && m.cpu.x == 7)
        #expect(try m.cpu.cycles == plainCycles())
    }

    @Test func drawsOnALayer() throws {
        // One byte an address: it reads memory's $0A and writes memory, the bytes layer 2's.
        let m = machine()
        m.addNative(at: 0x0310) { $0.run(into: 2) ?? 0 }
        try run(m)
        #expect(m.cpu.mem[0x2001] == 0x5F && m.layer(at: 0x2001) == 2)
        #expect(m.cpu.mem[0x2000] == 0xAA && m.layer(at: 0x2000) == 0)          // the code's own write
        #expect(m.cpu.mem[0x10] == 1 && m.cpu.y == 3 && m.cpu.a == 0x5F)
        #expect(try m.cpu.cycles == plainCycles() && !m.cpu.ioPages[0x20] && m.drawings.isEmpty)
        // The code writing there again: layer 0's.
        m.cpu.mem.replaceSubrange(0x0350 ..< 0x0356, with: [0xA9, 0x01, 0x8D, 0x01, 0x20, 0x60])
        try run(m, 0x0350)
        #expect(m.cpu.mem[0x2001] == 0x01 && m.layer(at: 0x2001) == 0)
    }

    @Test func pageWritesWithLayers() throws {
        // Memory's writes are told, whichever layer draws.
        let m = machine()
        var seen: [Int] = []
        m.onPageWrite = { seen.append($0) }
        m.addNative(at: 0x0310) { call in
            #expect(call.run(into: 1) == 23)
            #expect(call.machine.cpu.mem[0x2001] == 0x5F)
            return 23
        }
        try run(m)
        #expect(seen == [0x2000, 0x2001] && m.layer(at: 0x2001) == 1 && !m.drawsOnLayer)
        m.onPageWrite = nil
        #expect(m.cpu.watchedPages[0x20])                       // layer 1's byte still there
        m.clearLayers(page2: false)
        #expect(m.layer(at: 0x2001) == 0 && m.cpu.mem[0x2001] == 0x5F && !m.cpu.watchedPages[0x20])
    }

    @Test func discards() throws {
        let m = machine()
        var drawing = false
        m.addNative(at: 0x0310) { call in
            defer { drawing = call.machine.drawsOnLayer }
            return call.run(into: .discard) ?? 0
        }
        try run(m)
        #expect(m.cpu.mem[0x2001] == 0x0A && m.cpu.mem[0x10] == 1 && m.cpu.a == 0x5F && !drawing)
        // What it wrote there it reads back; nothing told, no layer.
        let n = machine()
        var seen: [Int] = []
        n.onPageWrite = { seen.append($0) }
        n.cpu.mem.replaceSubrange(0x0310 ..< 0x0319, with: [0xA9, 0x33, 0x8D, 0x01, 0x20, 0xAD, 0x01, 0x20, 0x60])
        n.addNative(at: 0x0310) { $0.run(into: .discard) ?? 0 }
        try run(n)
        #expect(n.cpu.mem[0x2001] == 0x0A && n.cpu.a == 0x33 && seen == [0x2000] && n.layer(at: 0x2001) == 0)
        #expect(!n.cpu.ioPages[0x20])
    }

    @Test func leavesTheCodeOut() throws {
        let m = machine()
        m.addNative(at: 0x0310) { call in
            call.cpu.y = 9
            return 4
        }
        try run(m)
        #expect(m.cpu.mem[0x10] == 0 && m.cpu.mem[0x2001] == 0x0A && m.cpu.y == 9 && m.cpu.x == 7)
        #expect(try m.cpu.cycles == plainCycles() - 23 + 4)
    }

    @Test func givesTheCyclesItWants() throws {
        let m = machine()
        m.addNative(at: 0x0310) { call in
            call.run()
            return 0
        }
        try run(m)
        #expect(try m.cpu.mem[0x10] == 1 && m.cpu.cycles == plainCycles() - 23)
    }

    @Test func nativesInside() throws {
        // The inner native draws on the outer's layer, or on its own.
        let m = machine()
        var depth = -1
        m.addNative(at: 0x0300) { $0.run(into: 1) ?? 0 }
        m.addNative(at: 0x0310) { call in
            depth = call.depth
            #expect(call.machine.drawsOnLayer)
            return call.run() ?? 0
        }
        try run(m)
        #expect(depth == 1 && m.layer(at: 0x2000) == 1 && m.layer(at: 0x2001) == 1)
        #expect(m.cpu.mem[0x2000] == 0xAA && m.cpu.mem[0x2001] == 0x5F && m.cpu.x == 7)

        let n = machine()
        n.addNative(at: 0x0300) { $0.run(into: 1) ?? 0 }
        n.addNative(at: 0x0310) { $0.run(into: 3) ?? 0 }
        try run(n)
        #expect(n.layer(at: 0x2000) == 1 && n.layer(at: 0x2001) == 3 && n.drawings.isEmpty)

        // Inside `.discard`: dropped too; one on a layer of its own writes memory.
        let d = machine()
        d.addNative(at: 0x0300) { call in
            #expect(call.run(into: .discard) != nil)
            #expect(!call.machine.copy().cpu.ioPages[0x20])       // a copy isn't in the drawing
            return 0
        }
        d.addNative(at: 0x0310) { $0.run() ?? 0 }
        try run(d)
        #expect(d.cpu.mem[0x2000] == 0 && d.cpu.mem[0x2001] == 0x0A && d.cpu.a == 0x5F && !d.cpu.ioPages[0x5F])
        let e = machine()
        e.addNative(at: 0x0300) { $0.run(into: .discard) ?? 0 }
        e.addNative(at: 0x0310) { $0.run(into: 2) ?? 0 }
        try run(e)
        #expect(e.cpu.mem[0x2000] == 0 && e.cpu.mem[0x2001] == 0x5F && e.layer(at: 0x2001) == 2)
    }

    @Test func switchedOff() throws {
        let m = machine()
        var ran = false
        m.addNative(at: 0x0310, name: "R") { _ in ran = true; return 0 }
        m.switchedOff = ["R"]
        #expect(!m.cpu.callTraps[0x0310])
        try run(m)
        #expect(!ran && m.cpu.mem[0x2001] == 0x5F)
        m.switchedOff = []
        #expect(m.cpu.callTraps[0x0310])
    }

    @Test func removed() throws {
        let m = machine()
        let id = m.addNative(at: 0x0310) { _ in 0 }
        m.removeHook(id)
        #expect(!m.cpu.callTraps[0x0310])
        try run(m)
        #expect(m.cpu.mem[0x2001] == 0x5F)
    }

    @Test func astray() throws {
        // A routine that never returns: the CPU goes on where it is, the drawing let go.
        let m = machine()
        m.cpu.mem.replaceSubrange(0x0310 ..< 0x0313, with: [0x4C, 0x10, 0x03])     // JMP $0310
        var cycles: UInt64?? = .none
        m.addNative(at: 0x0310, maxSteps: 100) { call in
            cycles = .some(call.run(into: .discard))
            return 0
        }
        m.cpu.sp = 0xFF
        #expect(throws: CPU6502.CPUError.self) { try m.cpu.call(0x0340, maxSteps: 1000) }
        #expect(cycles == .some(nil) && m.drawings.isEmpty && !m.cpu.ioPages[0x20] && m.cpu.pc == 0x0310)
    }

    @Test func layersOfThePages() {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        m.cpu.mem[0x2000] = 1
        m.cpu.mem[0x4000] = 2
        m.byteLayers[0] = 1
        m.byteLayers[0x2000] = 2
        m.layersUsed = true
        let one = m.hiresScreen(page2: false), two = m.hiresScreen(page2: true)
        #expect(one.bytes[0] == 1 && one.layers[0] == 1 && one.layers[1] == 0 && two.layers[0] == 2)
        // A copy of the machine: the layers with it.
        let c = m.copy()
        m.clearLayers(page2: true)
        #expect(m.layer(at: 0x2000) == 1 && m.layer(at: 0x4000) == 0 && m.cpu.mem[0x4000] == 2)
        m.clearLayers()
        #expect(m.layer(at: 0x2000) == 0 && c.layer(at: 0x2000) == 1 && c.layer(at: 0x4000) == 2)
    }

    @Test func showingLayers() {
        var screen = HiresScreen()
        screen.bytes[0] = 0x03
        screen.layers[0] = 1
        screen.bytes[85] = 0x04
        screen.layers[85] = 2
        #expect(screen.hasLayers && !HiresScreen().hasLayers)
        let one = screen.showing([0 ... 1])
        #expect(one.bytes[0] == 0x03 && one.bytes[85] == 0 && screen.showing([]).bytes[0] == 0)
        #expect(screen.showing([0 ... 0, 2 ... 2]).bytes[85] == 0x04)
    }

    // MARK: hidden layers and the bits that flow

    /// $0380: `JSR $0360 / RTS`; $0360 is where `draw` puts its code.  It runs
    /// stepping the machine (`Apple2Machine.step`), as a host does, which
    /// follows the bits (`cpu.call` steps the CPU alone); on `layer` as a
    /// native, else as the code's own.
    private func draw(_ m: Apple2Machine, _ code: [UInt8], on layer: UInt8? = nil) throws {
        m.cpu.mem.replaceSubrange(0x0360 ..< 0x0360 + code.count, with: code)
        m.cpu.mem.replaceSubrange(0x0380 ..< 0x0384, with: [0x20, 0x60, 0x03, 0x60])
        let id = layer.map { n in m.addNative(at: 0x0360) { $0.run(into: .layer(n)) ?? 0 } }
        m.cpu.sp = 0xFF
        m.cpu.push(0xFF)                        // RTS lands on $FFFF: the end
        m.cpu.push(0xFE)
        m.cpu.pc = 0x0380
        for _ in 0 ..< 1000 where m.cpu.pc != 0xFFFF { try m.step() }
        #expect(m.cpu.pc == 0xFFFF)
        if let id { m.removeHook(id) }
    }

    /// A machine with layer 1 hidden, its $2001 the code's own $0A.
    private func hidden() -> Apple2Machine {
        let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
        m.hiddenLayers = [1]
        m.cpu.mem[0x2001] = 0x0A
        return m
    }

    /// `LDA $2001 / ORA #t / STA $2001 / RTS`: a text's code.
    private func text(_ dots: UInt8) -> [UInt8] { [0xAD, 0x01, 0x20, 0x09, dots, 0x8D, 0x01, 0x20, 0x60] }

    /// DRAW_SPRITE's merge, `(old AND NOT mask) OR set`: `LDA #mask / EOR #$FF / AND $2001 / ORA #set / STA $2001 / RTS`.
    private func spriteMerge(mask: UInt8, set: UInt8) -> [UInt8] {
        [0xA9, mask, 0x49, 0xFF, 0x2D, 0x01, 0x20, 0x09, set, 0x8D, 0x01, 0x20, 0x60]
    }

    /// The other order, as HORIZONTAL_LINE's edge bytes: `LDA $2001 / AND #keep / ORA #set / STA $2001 / RTS`.
    private func lineMerge(keep: UInt8, set: UInt8) -> [UInt8] {
        [0xAD, 0x01, 0x20, 0x29, keep, 0x09, set, 0x8D, 0x01, 0x20, 0x60]
    }

    @Test func hiddenLayer() throws {
        // The text, layer 1, lights $55 in $2001 (the code's own $0A): hidden dots.
        let m = hidden()
        try draw(m, text(0x55), on: 1)
        #expect(m.cpu.mem[0x2001] == 0x5F && m.layer(at: 0x2001) == 1 && m.hiddenDots(at: 0x2001) == 0x55)
        #expect(m.hiddenLayers == [1] && m.copy().hiddenDots(at: 0x2001) == 0x55 && m.passedDots(at: 0x2001) == 0)
        // A sprite on layer 2 with the silhouette $0F sets dots 0 and 2 (the text's too) and clears
        // 1 and 3: it passes dots 4 to 6 through, the text's 4 and 6 among them; the byte is $55.
        try draw(m, spriteMerge(mask: 0x0F, set: 0x05), on: 2)
        #expect(m.cpu.mem[0x2001] == 0x55 && m.layer(at: 0x2001) == 2)
        #expect(m.hiddenDots(at: 0x2001) == 0x50 && m.passedDots(at: 0x2001) == 0x70 && m.copy().passedDots(at: 0x2001) == 0x70)
        let screen = m.hiresScreen(page2: false)
        #expect(screen.hidden[1] == 0x50 && screen.passed[1] == 0x70 && screen.showing([0 ... 1, 2 ... 2]).bytes[1] == 0x05)
        // In layer 2's image the dots it passed through (pixels 4 to 6 of the byte, 11 to 13 of the
        // line) are transparent; the dots it set (pixels 7 and 9), the gap between them (a dark shade
        // of their colour) and the one it cleared after them (black) are not.
        let top = try #require(Screen.images(screen, groups: [0 ... 1, 2 ... 2])[1])
        let p = pixels(top.image)
        #expect(p[22 ..< 28].allSatisfy { $0 == 0 })
        #expect(p[14] != 0 && p[14] != Screen.black && p[18] != 0 && p[16] != 0 && p[20] == Screen.black)
        // The code's own drawing (layer 0) that sets the byte takes them back; so does clearing the layers.
        try draw(m, [0xA9, 0x00, 0x8D, 0x01, 0x20, 0x60])
        #expect(m.layer(at: 0x2001) == 0 && m.hiddenDots(at: 0x2001) == 0 && m.passedDots(at: 0x2001) == 0)
        try draw(m, text(0x03), on: 1)
        #expect(m.hiddenDots(at: 0x2001) == 0x03)
        m.clearLayers()
        #expect(m.hiddenDots(at: 0x2001) == 0 && m.passedDots(at: 0x2001) == 0)
    }

    @Test func dotsPassedThroughAreHiddenOnes() throws {
        // The two orders the engine merges in, a mask over the text's $55 on $5F.
        for code in [spriteMerge(mask: 0x0F, set: 0x05), lineMerge(keep: 0xF0, set: 0x05)] {
            let m = hidden()
            try draw(m, text(0x55), on: 1)
            try draw(m, code, on: 2)
            #expect(m.cpu.mem[0x2001] == 0x55 && m.hiddenDots(at: 0x2001) == 0x50 && m.passedDots(at: 0x2001) == 0x70)
        }
        // A sprite that sets none of the dots it covers (black): the text's dots inside it gone.
        let black = hidden()
        try draw(black, text(0x55), on: 1)
        try draw(black, spriteMerge(mask: 0x0F, set: 0x00), on: 2)
        #expect(black.cpu.mem[0x2001] == 0x50 && black.hiddenDots(at: 0x2001) == 0x50 && black.passedDots(at: 0x2001) == 0x70)
        // A solid one: nothing of the text left, all its dots the sprite's.
        let solid = hidden()
        try draw(solid, text(0x55), on: 1)
        try draw(solid, spriteMerge(mask: 0x7F, set: 0x7F), on: 2)
        #expect(solid.cpu.mem[0x2001] == 0x7F && solid.hiddenDots(at: 0x2001) == 0 && solid.passedDots(at: 0x2001) == 0)
    }

    @Test func passedDotsShowTheLayersUnder() throws {
        // No hidden layer: a sprite over the code's own $0A passes dots 4 to 6 through.
        let m = machine()
        try draw(m, spriteMerge(mask: 0x0F, set: 0x05), on: 2)
        #expect(m.cpu.mem[0x2001] == 0x05 && m.passedDots(at: 0x2001) == 0x70)
        // Another sprite on the same layer draws dots 4 and 5: only 6 is still passed through.
        try draw(m, spriteMerge(mask: 0x30, set: 0x10), on: 2)
        #expect(m.cpu.mem[0x2001] == 0x15 && m.passedDots(at: 0x2001) == 0x40)
        // A sprite on another layer: the dots it passes through, whoever drew them.
        try draw(m, spriteMerge(mask: 0x01, set: 0x01), on: 3)
        #expect(m.layer(at: 0x2001) == 3 && m.passedDots(at: 0x2001) == 0x7E)
        // The code's own drawing: none.
        try draw(m, lineMerge(keep: 0xFE, set: 0x00))
        #expect(m.layer(at: 0x2001) == 0 && m.passedDots(at: 0x2001) == 0)
    }

    @Test func bitsPassedThroughInPlace() throws {
        // `$2001` as the text left it ($5F, $55 of it hidden), then what the code does with it:
        // its hidden dots, and the dots it passed through, of `$2001` and `$2002`.
        func result(_ code: [UInt8], on layer: UInt8? = 2) throws -> (hidden: UInt8, passed: UInt8, byte: UInt8, other: UInt8) {
            let m = hidden()
            try draw(m, text(0x55), on: 1)
            try draw(m, code, on: layer)
            #expect(m.hiddenDots(at: 0x2002) == 0)              // a copy elsewhere is the drawing's
            return (m.hiddenDots(at: 0x2001), m.passedDots(at: 0x2001), m.cpu.mem[0x2001], m.cpu.mem[0x2002])
        }
        // Through X and back: all of it as it was.
        let back = try result([0xAD, 0x01, 0x20, 0xAA, 0xA9, 0x00, 0x8A, 0x8D, 0x01, 0x20, 0x60])   // LDA / TAX / LDA #0 / TXA / STA
        #expect(back.byte == 0x5F && back.hidden == 0x55 && back.passed == 0x7F)
        // ORA sets dot 5, the rest passes; EOR inverts dots 0 to 3, the rest passes.
        let ored = try result([0xAD, 0x01, 0x20, 0x09, 0x20, 0x8D, 0x01, 0x20, 0x60])            // LDA / ORA #$20 / STA
        #expect(ored.byte == 0x7F && ored.hidden == 0x55 && ored.passed == 0x5F)
        let eored = try result([0xAD, 0x01, 0x20, 0x49, 0x0F, 0x8D, 0x01, 0x20, 0x60])           // LDA / EOR #$0F / STA
        #expect(eored.byte == 0x50 && eored.hidden == 0x50 && eored.passed == 0x70)
        // Moved by a shift, through memory or the stack, computed: the drawing's own.
        #expect(try result([0xAD, 0x01, 0x20, 0x0A, 0x8D, 0x01, 0x20, 0x60]) == (0, 0, 0xBE, 0))            // ASL A
        #expect(try result([0xAD, 0x01, 0x20, 0x85, 0x10, 0xA5, 0x10, 0x8D, 0x01, 0x20, 0x60]).passed == 0)   // via $10
        #expect(try result([0xAD, 0x01, 0x20, 0x48, 0x68, 0x8D, 0x01, 0x20, 0x60]).passed == 0)            // via the stack
        #expect(try result([0xAD, 0x01, 0x20, 0x18, 0x69, 0x00, 0x8D, 0x01, 0x20, 0x60]).passed == 0)      // CLC / ADC #0
        #expect(try result([0xA9, 0x5F, 0x8D, 0x01, 0x20, 0x60]) == (0, 0, 0x5F, 0))                     // LDA #$5F: the same byte
        // Copied into another byte: the drawing's own there.
        #expect(try result([0xAD, 0x01, 0x20, 0x8D, 0x02, 0x20, 0x60]).other == 0x5F)
        // The code's own drawing (layer 0) keeps the hidden dots it passes through; passes none itself.
        let own = try result([0xAD, 0x01, 0x20, 0x29, 0xF0, 0x8D, 0x01, 0x20, 0x60], on: nil)          // LDA / AND #$F0 / STA
        #expect(own.byte == 0x50 && own.hidden == 0x50 && own.passed == 0)
        // A text's own layer: the dots it lights, whatever the code does.
        let again = hidden()
        try draw(again, text(0x55), on: 1)
        try draw(again, [0xA9, 0x22, 0x8D, 0x02, 0x20, 0x60], on: 1)
        #expect(again.hiddenDots(at: 0x2002) == 0x22)
    }

    @Test func aCopyGoesOnWithTheBitsFollowed() throws {
        // A copy made between a load and its store follows the bits as the machine does:
        // both keep the text's dots the store passes through.
        let m = hidden()
        try draw(m, text(0x55), on: 1)
        m.cpu.mem.replaceSubrange(0x0360 ..< 0x0366, with: [0xAD, 0x01, 0x20, 0x8D, 0x01, 0x20])   // LDA $2001 / STA $2001
        m.cpu.pc = 0x0360
        try m.step()
        let c = m.copy()
        try m.step()
        try c.step()
        #expect(m.hiddenDots(at: 0x2001) == 0x55 && c.hiddenDots(at: 0x2001) == 0x55)
    }

    @Test func aByteWithItself() throws {
        // $2001 as the text left it ($5F, $55 hidden): x EOR x is 0, the code's own black; x AND x
        // and x OR x are x, all of it passed through.
        func result(_ op: UInt8) throws -> (byte: UInt8, passed: UInt8, hidden: UInt8) {
            let m = hidden()
            try draw(m, text(0x55), on: 1)
            try draw(m, [0xAD, 0x01, 0x20, op, 0x01, 0x20, 0x8D, 0x01, 0x20, 0x60], on: 2)   // LDA / op $2001 / STA
            return (m.cpu.mem[0x2001], m.passedDots(at: 0x2001), m.hiddenDots(at: 0x2001))
        }
        #expect(try result(0x4D) == (0x00, 0x00, 0x00))          // EOR
        #expect(try result(0x2D) == (0x5F, 0x7F, 0x55))          // AND
        #expect(try result(0x0D) == (0x5F, 0x7F, 0x55))          // ORA
    }

    @Test func passedDotsAgainstTheCodeOnTheByteInverted() throws {
        // The dots a merge passes through are those that follow the byte: with its dots inverted
        // the code stores them inverted, and the others as before.
        var random = SplitMix(seed: 11)
        for _ in 0 ..< 300 {
            let old = UInt8.random(in: 0 ... 0xFF, using: &random)
            let mask = UInt8.random(in: 0 ... 0xFF, using: &random), set = UInt8.random(in: 0 ... 0xFF, using: &random)
            let code = Bool.random(using: &random) ? spriteMerge(mask: mask, set: set) : lineMerge(keep: mask, set: set)
            let m = machine()
            m.cpu.mem[0x2001] = old
            try draw(m, code, on: 2)
            let inverted = machine()
            inverted.cpu.mem[0x2001] = old ^ 0x7F
            try draw(inverted, code)
            #expect(m.passedDots(at: 0x2001) == (m.cpu.mem[0x2001] ^ inverted.cpu.mem[0x2001]) & 0x7F)
        }
    }

    @Test func followingTheBitsChangesNothing() throws {
        // The code runs as ever: memory, registers and cycles the same with hidden layers or without.
        func run(hiddenLayers: Set<UInt8>) throws -> (memory: [UInt8], regs: CPU6502.Registers, cycles: UInt64) {
            let m = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
            m.hiddenLayers = hiddenLayers
            m.cpu.mem[0x2001] = 0x0A
            try draw(m, text(0x55), on: 1)
            try draw(m, spriteMerge(mask: 0x0F, set: 0x05), on: 2)
            return (m.cpu.mem, m.cpu.registers, m.cpu.cycles)
        }
        let with = try run(hiddenLayers: [1]), without = try run(hiddenLayers: [])
        #expect(with.memory == without.memory && with.regs == without.regs && with.cycles == without.cycles)
    }

    @Test func hiddenDotsLeftAgainstTheCodeOnATextFreePage() throws {
        // The dots left are those lit in the byte stored and not on the page without the text.
        var random = SplitMix(seed: 7)
        var checked = 0
        for _ in 0 ..< 300 {
            let own = UInt8.random(in: 0 ... 0xFF, using: &random), dots = UInt8.random(in: 0 ... 0x7F, using: &random)
            let mask = UInt8.random(in: 0 ... 0xFF, using: &random), set = UInt8.random(in: 0 ... 0xFF, using: &random)
            let code = Bool.random(using: &random) ? spriteMerge(mask: mask, set: set) : lineMerge(keep: mask, set: set)
            let m = hidden()
            m.cpu.mem[0x2001] = own
            try draw(m, text(dots), on: 1)
            let hiddenBefore = m.hiddenDots(at: 0x2001), pageBefore = m.cpu.mem[0x2001]
            try draw(m, code, on: 2)
            // The same code on the page without the text.
            let clean = Apple2Machine(model: .apple2e, rom: nil, diskROM: nil)
            clean.cpu.mem[0x2001] = pageBefore & ~hiddenBefore
            try draw(clean, code)
            let expected = hiddenBefore & m.cpu.mem[0x2001] & ~clean.cpu.mem[0x2001] & 0x7F
            #expect(m.hiddenDots(at: 0x2001) == expected)
            checked += hiddenBefore != 0 ? 1 : 0
        }
        #expect(checked > 200)
    }

    /// The image's 560 × rows RGBA pixels.
    private func pixels(_ image: CGImage) -> [UInt32] {
        var p = [UInt32](repeating: 0, count: image.width * image.height)
        let data = image.dataProvider!.data! as Data
        _ = p.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return p
    }

    @Test func groupsMakeThePageAsOne() throws {
        // $2001 is layer 1's $01 (pixel 7), $2000 layer 0's $40 (pixel 6):
        // both white, as on one page; each group only its bytes' dots.
        var screen = HiresScreen()
        screen.bytes[0] = 0x40
        screen.bytes[1] = 0x01
        screen.layers[1] = 1
        screen.bytes[40 * 191 + 39] = 0x7F          // layer 2: not shown
        screen.layers[40 * 191 + 39] = 2
        let images = Screen.images(screen, groups: [0 ... 0, 1 ... 1])
        let base = try #require(images[0]), top = try #require(images[1])
        #expect(top.lines == 0 ..< 1 && top.image.width == 560 && top.image.height == 2 && base.lines == 0 ..< 192)
        let p = pixels(top.image), under = pixels(base.image)
        #expect(p[0 ..< 14].allSatisfy { $0 == 0 } && p[14] == Screen.white && p[15] == Screen.white)
        #expect(p[16 ..< 28].allSatisfy { $0 == Screen.black } && p[28 ..< 560].allSatisfy { $0 == 0 })
        #expect(Array(p[560 ..< 1120]) == Array(p[0 ..< 560]))
        // Layer 0's group: the page of the layers shown, opaque (layer 2 not in it);
        // layer 1's over it changes nothing.
        let whole = pixels(try #require(Screen.image(screen.showing([0 ... 1]))))
        #expect(under == whole && under[12] == Screen.white && under[14] == Screen.white)
        var shown = under
        for (d, v) in p.enumerated() where v != 0 { shown[d] = v }
        #expect(shown == whole)
        #expect(Screen.images(HiresScreen(), groups: [1 ... 1])[0] == nil)
    }
}

/// A seeded generator, for tests that must repeat.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
