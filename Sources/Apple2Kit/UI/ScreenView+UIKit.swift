#if canImport(UIKit) && !os(watchOS)
import GameController
import SwiftUI
import UIKit

struct ScreenRepresentable: UIViewRepresentable {
    let emulator: EmulatorModel
    let style: Screen.Style

    func makeUIView(context: Context) -> ScreenUIView {
        ScreenUIView(emulator: emulator, style: style)
    }

    func updateUIView(_ view: ScreenUIView, context: Context) {
        view.emulator = emulator
        view.style = style
    }
}

/// Runs the emulator with a display link and shows each frame's picture in
/// its layer.  Keys: a hardware keyboard's (`pressesBegan`, ⌥ the push
/// buttons), the on-screen keyboard's (`UIKeyInput`, a tap shows or hides
/// it), the Siri Remote's on tvOS.
final class ScreenUIView: UIView, UIKeyInput {
    var emulator: EmulatorModel
    var style: Screen.Style
    private var link: CADisplayLink?

    init(emulator: EmulatorModel, style: Screen.Style) {
        self.emulator = emulator
        self.style = style
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        layer.contentsGravity = .resize         // 560 × 192 dots on a 280:192 view
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .linear
        #if !os(tvOS)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        #endif
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayFrame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // the keys at once from a hardware keyboard; the on-screen one waits for a tap
        #if os(tvOS)
        becomeFirstResponder()
        #else
        if GCKeyboard.coalesced != nil { becomeFirstResponder() }
        #endif
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        if let image = emulator.frame(at: link.targetTimestamp, style: style) { layer.contents = image }
    }

    @objc private func tapped() {
        if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() }
    }

    override var canBecomeFirstResponder: Bool { true }
    #if os(tvOS)
    override var canBecomeFocused: Bool { true }
    #endif

    // MARK: hardware keys

    /// The Apple key for a press: a keyboard's, or the Siri Remote's.
    private func ascii(for press: UIPress) -> UInt8? {
        if let key = press.key { return KeyMap.ascii(for: key, lowercase: emulator.model == .apple2e) }
        #if os(tvOS)
        return KeyMap.ascii(for: press.type)
        #else
        return nil
        #endif
    }

    /// Takes the presses that are Apple keys or buttons (not given to the
    /// text input then); the rest go on (⌘ shortcuts, Menu).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { press in
            if let key = press.key, let button = KeyMap.button(for: key) {
                emulator.setButton(button, pressed: true)
            } else if let ascii = ascii(for: press) {
                pressControl(false)
                emulator.press(ascii)
            } else {
                return true
            }
            return false
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = released(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = released(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Releases the buttons among `presses`; returns those that aren't ours.
    private func released(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { press in
            if let key = press.key, let button = KeyMap.button(for: key) {
                emulator.setButton(button, pressed: false)
                return false
            }
            return ascii(for: press) == nil
        }
    }

    // MARK: the on-screen keyboard

    /// Ctrl from the key bar: the next key typed is a control key.
    private var control = false

    private func pressControl(_ on: Bool) {
        control = on
        #if os(iOS)
        controlItem?.isSelected = on
        #endif
    }

    var hasText: Bool { true }                 // delete always comes

    func insertText(_ text: String) {
        if control {
            pressControl(false)
            if let c = KeyMap.ascii(characters: text, ignoringModifiers: text, control: true, lowercase: false) {
                emulator.press(c)
            }
            return
        }
        emulator.type(text)                     // \n is return; capitals on the ][ and ][+
    }

    func deleteBackward() { emulator.press(KeyMap.left) }

    // typed as it is: no corrections, capitals or smart punctuation
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    #if os(iOS)
    private var controlItem: UIBarButtonItem?

    /// The keys the on-screen keyboard lacks: esc, ctrl (for the next key),
    /// the arrows.
    private lazy var keyBar: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        func key(_ title: String, _ ascii: UInt8) -> UIBarButtonItem {
            UIBarButtonItem(title: title, primaryAction: UIAction { [unowned self] _ in
                pressControl(false)
                emulator.press(ascii)
            })
        }
        let control = UIBarButtonItem(title: "ctrl", primaryAction: UIAction { [unowned self] _ in
            pressControl(!self.control)
        })
        controlItem = control
        bar.items = [key("esc", KeyMap.escape), control, .flexibleSpace(),
                     key("←", KeyMap.left), key("→", KeyMap.right), key("↑", KeyMap.up), key("↓", KeyMap.down)]
        bar.sizeToFit()
        return bar
    }()

    override var inputAccessoryView: UIView? { keyBar }
    #endif
}
#endif
