import MOS6502

/// Where a native's code draws (`NativeCall.run(into:)`).
///
/// The hi-res pages hold one byte at an address, as on the Apple: main
/// memory's.  Each byte of $2000-$5FFF also has a layer, the number of the
/// drawing that wrote it last (`Apple2Machine.layer(at:)`): 0 the code's
/// own, others a native's.  A host shows the layers it wants, in groups,
/// each an image over the ones before it (`HiresScreen.layers`,
/// `Screen.images`).
///
/// A hidden layer (`Apple2Machine.hiddenLayers`) is in memory as any other,
/// but its dots aren't shown: the host draws them its own way (a text in a
/// modern font) between the groups.  A drawing over a byte owns only the
/// dots its code changes or sets; those it passes through as they were (a
/// sprite's mask lets them through, `BitFlow`) stay what they were: hidden
/// dots hidden, and on a layer over 0 transparent in its group's image, the
/// host's drawing and the layers under it showing there.
public nonisolated enum DrawTarget: Hashable, Sendable, ExpressibleByIntegerLiteral {
    /// Main memory's pages, each byte the code writes there layer `n`'s
    /// (0: `main`).  It reads memory, as ever.
    case layer(UInt8)
    /// Nowhere: the code reads back what it wrote while it runs, then it is
    /// dropped.  Memory and its layers stay as they were.
    case discard

    /// Main memory's pages, the bytes written layer 0's: the code's own.
    public static let main = DrawTarget.layer(0)

    /// `layer(value)`: `run(into: 2)`.
    public init(integerLiteral value: UInt8) { self = .layer(value) }
}

/// One native's code drawing on its target (`NativeCall.run(into:)`).
nonisolated final class LayerDrawing {
    var target = DrawTarget.main
    /// With `.discard`: what it wrote, where `written`.
    var bytes = [UInt8](repeating: 0, count: Apple2Machine.hiresSize)
    var written = [Bool](repeating: false, count: Apple2Machine.hiresSize)
    var offsets: [Int] = []
}

nonisolated extension Apple2Machine {
    /// The layer of the byte at `address` ($2000-$5FFF): the drawing that
    /// wrote it last (`DrawTarget`), 0 the code's own.
    public func layer(at address: Int) -> UInt8 {
        byteLayers[address - Apple2Machine.hiresBase]
    }

    /// The layers whose dots aren't shown (`DrawTarget`, above): the host
    /// draws them.  Layer 0 can't be hidden.
    public var hiddenLayers: Set<UInt8> {
        get { Set(layerHidden.indices.filter { layerHidden[$0] }.map(UInt8.init)) }
        set {
            precondition(!newValue.contains(0), "layer 0 can't be hidden")
            layerHidden = (0 ..< 256).map { newValue.contains(UInt8($0)) }
        }
    }

    /// The dots (bits 0-6) of the byte at `address` ($2000-$5FFF) a hidden
    /// layer lit and none has covered since.
    public func hiddenDots(at address: Int) -> UInt8 {
        hiddenDots[address - Apple2Machine.hiresBase]
    }

    /// The dots (bits 0-6) of the byte at `address` ($2000-$5FFF) its
    /// layer's code passed through as they were (`BitFlow`): not its own
    /// drawing, the layers under it show there (`Screen.images`).  None on
    /// layer 0 or a hidden layer.
    public func passedDots(at address: Int) -> UInt8 {
        passedDots[address - Apple2Machine.hiresBase]
    }

    /// Every byte of both pages, or of page 1 or 2, layer 0's again, no
    /// dot hidden or passed through; the bytes stay as they are.
    public func clearLayers(page2: Bool? = nil) {
        let range = switch page2 {
        case nil: 0 ..< Apple2Machine.hiresSize
        case false?: 0 ..< 0x2000
        case true?: 0x2000 ..< 0x4000
        }
        byteLayers.withUnsafeMutableBufferPointer { $0[range].update(repeating: 0) }
        hiddenDots.withUnsafeMutableBufferPointer { $0[range].update(repeating: 0) }
        passedDots.withUnsafeMutableBufferPointer { $0[range].update(repeating: 0) }
        if drawings.isEmpty && layersUsed && !byteLayers.contains(where: { $0 != 0 }) && !hiddenDots.contains(where: { $0 != 0 }) {
            layersUsed = false
            updateWatchedPages()
            updateFlowTracking()
        }
    }

    /// A native's code draws on its target (`NativeCall.run(into:)`) now.
    public var drawsOnLayer: Bool { !drawings.isEmpty }

    /// The CPU watches $20-$5F while a host follows the writes there
    /// (`onPageWrite`) or a byte may be another layer's than 0, or have
    /// hidden dots (`layersUsed`): each write marks its byte the current
    /// drawing's (`pageWritten`).
    func updateWatchedPages() {
        let watch = onPageWrite != nil || layersUsed
        for page in Apple2Machine.hiresPages { cpu.watchedPages[page] = watch }
    }

    /// From here the code's writes of $2000-$5FFF go to `target`.
    func beginDrawing(on target: DrawTarget) {
        if drawings.count == drawingPool.count { drawingPool.append(LayerDrawing()) }
        let drawing = drawingPool[drawings.count]
        drawing.target = target
        drawings.append(drawing)
        if case .layer(let n) = target, n != 0, !layersUsed {
            layersUsed = true
            updateWatchedPages()
        }
        drawInnermost()
    }

    /// The innermost drawing ends.
    func endDrawing() {
        let d = drawings.removeLast()
        for offset in d.offsets { d.written[offset] = false }
        d.offsets.removeAll(keepingCapacity: true)
        drawInnermost()
    }

    /// The writes go where the innermost drawing draws: a layer's with the
    /// byte's layer (`pageWritten`), `.discard`'s through the CPU's I/O
    /// pages (`drawnRead`, `drawnWrite`).
    private func drawInnermost() {
        switch drawings.last?.target ?? .main {
        case .layer(let n):
            drawLayer = n
            restorePages()
            flowSuspended = layerHidden[Int(n)]
            updateFlowTracking()
        case .discard:
            drawLayer = 0
            flowSuspended = true
            updateFlowTracking()
            guard pagesBeforeDrawing.isEmpty else { return }
            pagesBeforeDrawing = Array(cpu.ioPages[Apple2Machine.hiresPages])
            for page in Apple2Machine.hiresPages { cpu.ioPages[page] = true }
        }
    }

    /// The bits the registers hold of the pages' bytes are followed while a
    /// byte may be another layer's than 0, except as the code draws a hidden
    /// layer's (the dots it lights are its own) or `.discard`'s: from none,
    /// each time it starts (`BitFlow`).
    func updateFlowTracking() {
        let on = layersUsed && !flowSuspended
        if on && !flowTracking { flow = BitFlow() }
        if !on { flow.store = .init() }
        flowTracking = on
    }

    /// The CPU's I/O pages $20-$5F as they were before `.discard` took them.
    func restorePages() {
        guard !pagesBeforeDrawing.isEmpty else { return }
        for (i, page) in Apple2Machine.hiresPages.enumerated() { cpu.ioPages[page] = pagesBeforeDrawing[i] }
        pagesBeforeDrawing = []
    }

    /// The CPU's I/O pages, those $20-$5F as without a drawing (a copy, a state).
    var restingIOPages: [Bool] {
        var pages = cpu.ioPages
        if !pagesBeforeDrawing.isEmpty { pages.replaceSubrange(Apple2Machine.hiresPages, with: pagesBeforeDrawing) }
        return pages
    }

    /// Whether the code's reads and writes of $2000-$5FFF go to `.discard`.
    var discards: Bool { !pagesBeforeDrawing.isEmpty }

    /// A read of $2000-$5FFF while the code draws on `.discard`: what it
    /// wrote there (or a `.discard` it runs inside), else memory's.
    func drawnRead(_ address: UInt16) -> UInt8 {
        let a = Int(address), offset = a - Apple2Machine.hiresBase
        for d in drawings.reversed() {
            guard d.target == .discard else { break }
            if d.written[offset] { return d.bytes[offset] }
        }
        return cpu.mem[a]
    }

    /// A write of $2000-$5FFF while the code draws on `.discard`: kept
    /// there until the drawing ends.
    func drawnWrite(_ address: UInt16, _ value: UInt8) {
        let d = drawings[drawings.count - 1], offset = Int(address) - Apple2Machine.hiresBase
        if !d.written[offset] {
            d.written[offset] = true
            d.offsets.append(offset)
        }
        d.bytes[offset] = value
    }
}
