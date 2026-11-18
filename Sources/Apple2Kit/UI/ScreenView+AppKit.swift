#if os(macOS)
import AppKit
import SwiftUI

struct ScreenRepresentable: NSViewRepresentable {
    let emulator: Apple2
    let style: Screen.Style

    func makeNSView(context: Context) -> ScreenNSView {
        ScreenNSView(emulator: emulator, style: style)
    }

    func updateNSView(_ view: ScreenNSView, context: Context) {
        view.emulator = emulator
        view.style = style
    }
}

/// Runs the emulator with a display link, shows each frame's picture in its
/// layer, and hands key presses and the ⌥ keys (push buttons) to it.  With
/// the mouse card in, a click captures the Mac's pointer (hidden and held
/// still, its movements and button the card's) until ⌘ is pressed, the window going
/// to the back or the card taken out.
final class ScreenNSView: NSView {
    var emulator: Apple2 {
        didSet { if emulator !== oldValue { releaseMouse(of: oldValue) } }
    }
    var style: Screen.Style
    private var link: CADisplayLink?
    /// The pointer is captured; the window's `acceptsMouseMovedEvents` before.
    private var captured: Bool?
    private var resignObserver: NSObjectProtocol?

    init(emulator: Apple2, style: Screen.Style) {
        self.emulator = emulator
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize        // 560 × 192 dots on a 280:192 view
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        releaseMouse()
        resignObserver.map(NotificationCenter.default.removeObserver)
        resignObserver = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseMouse() }
        }
        let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        window.makeFirstResponder(self)
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        if captured != nil, !emulator.mouse { releaseMouse() }
        if let image = emulator.frame(at: link.targetTimestamp, style: style) { layer?.contents = image }
    }

    // MARK: the mouse

    /// A click: the focus; with the mouse card in, the pointer captured, and
    /// once it is, the card's button.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard emulator.mouse else { return }
        if captured != nil { emulator.mouseButton(down: true) } else { captureMouse() }
    }

    override func mouseUp(with event: NSEvent) {
        if captured != nil { emulator.mouseButton(down: false) }
    }

    override func mouseMoved(with event: NSEvent) { moveMouse(event) }
    override func mouseDragged(with event: NSEvent) { moveMouse(event) }

    /// The pointer's movement (points, y down), as far on the Apple's
    /// screen as on the view: 280 counts across it.
    private func moveMouse(_ event: NSEvent) {
        guard captured != nil, bounds.width > 0 else { return }
        let scale = 280 / bounds.width
        emulator.moveMouse(dx: event.deltaX * scale, dy: event.deltaY * scale)
    }

    private func captureMouse() {
        guard captured == nil, let window else { return }
        captured = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        emulator.mouseCaptured = true
    }

    /// The pointer back to the Mac, the card's button up.
    private func releaseMouse(of apple: Apple2? = nil) {
        guard let accepted = captured else { return }
        captured = nil
        window?.acceptsMouseMovedEvents = accepted
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        let apple = apple ?? emulator
        apple.mouseButton(down: false)
        apple.mouseCaptured = false
    }

    // MARK: keys

    /// A key down, by its key code until it goes up; the Mac's repeats are
    /// left out (the //e repeats itself).
    override func keyDown(with event: NSEvent) {
        if let key = KeyMap.ascii(for: event, lowercase: emulator.typesLowercase) {
            if !event.isARepeat { emulator.keyDown(key, id: Int(event.keyCode)) }
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        emulator.keyUp(id: Int(event.keyCode))
        super.keyUp(with: event)
    }

    override func resignFirstResponder() -> Bool {
        emulator.releaseKeys()
        releaseMouse()
        return super.resignFirstResponder()
    }

    /// ⌘ (either) lets a captured pointer go: the ⌥ keys are the Apple's,
    /// ⌘ isn't.
    override func flagsChanged(with event: NSEvent) {
        if captured != nil, event.keyCode == 55 || event.keyCode == 54, event.modifierFlags.contains(.command) {
            releaseMouse()
        }
        if let button = KeyMap.buttonKeys[event.keyCode] {
            // the device-dependent bits: left ⌥ $20, right ⌥ $40
            let mask: UInt = button == 0 ? 0x20 : 0x40
            emulator.setButton(button, pressed: event.modifierFlags.rawValue & mask != 0)
        }
        super.flagsChanged(with: event)
    }
}
#endif
