#if os(macOS)
import AppKit
import SwiftUI

struct ScreenRepresentable: NSViewRepresentable {
    let emulator: EmulatorModel
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
/// layer, and hands key presses and the ⌥ keys (push buttons) to it.
final class ScreenNSView: NSView {
    var emulator: EmulatorModel
    var style: Screen.Style
    private var link: CADisplayLink?

    init(emulator: EmulatorModel, style: Screen.Style) {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        window?.makeFirstResponder(self)
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        if let image = emulator.frame(at: link.targetTimestamp, style: style) { layer?.contents = image }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if let key = KeyMap.ascii(for: event, lowercase: emulator.model == .apple2e) {
            emulator.press(key)
        } else {
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if let button = KeyMap.buttonKeys[event.keyCode] {
            // the device-dependent bits: left ⌥ $20, right ⌥ $40
            let mask: UInt = button == 0 ? 0x20 : 0x40
            emulator.setButton(button, pressed: event.modifierFlags.rawValue & mask != 0)
        }
        super.flagsChanged(with: event)
    }
}
#endif
