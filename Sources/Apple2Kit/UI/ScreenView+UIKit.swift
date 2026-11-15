#if canImport(UIKit) && !os(watchOS)
import GameController
import SwiftUI
import UIKit

#if os(tvOS)
/// On tvOS the screen is the view of a `GCEventViewController`, so that a
/// gamepad plays only as the joystick: its d-pad, A and B (Menu) would
/// otherwise come to UIKit as well, as the arrows, return and leaving the
/// app.  The Siri Remote goes on being the keys (and Menu going back) until
/// a gamepad is played.
struct ScreenRepresentable: UIViewControllerRepresentable {
    let emulator: Apple2
    let style: Screen.Style

    func makeUIViewController(context: Context) -> ScreenViewController {
        ScreenViewController(screen: ScreenUIView(emulator: emulator, style: style))
    }

    func updateUIViewController(_ controller: ScreenViewController, context: Context) {
        controller.screen.emulator = emulator
        controller.screen.style = style
    }
}

final class ScreenViewController: GCEventViewController {
    let screen: ScreenUIView
    private var observers: [NSObjectProtocol] = []

    init(screen: ScreenUIView) {
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() { view = screen }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = true
        GCController.controllers().forEach(watch)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if let controller = note.object as? GCController { self?.watch(controller) }
                }
            },
            center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let current = GCController.current, current.extendedGamepad == nil { self?.gamepadInUse(false) }
                }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if !GCController.controllers().contains(where: { $0.extendedGamepad != nil }) {
                        self?.gamepadInUse(false)
                    }
                }
            },
        ]
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [screen] }

    /// UIKit gets the controllers' presses only while a gamepad isn't in
    /// use: from when one is played (not when it connects: a gamepad
    /// connected doesn't make the Siri Remote's presses go) until the Siri
    /// Remote is, or the last gamepad goes.  The Simulator's remote isn't a
    /// controller: there a gamepad played stays in use.
    private func watch(_ controller: GCController) {
        if let pad = controller.extendedGamepad {
            pad.valueChangedHandler = { [weak self] _, _ in
                DispatchQueue.main.async { self?.gamepadInUse(true) }
            }
        } else {
            controller.microGamepad?.valueChangedHandler = { [weak self] _, _ in
                DispatchQueue.main.async { self?.gamepadInUse(false) }
            }
        }
    }

    private func gamepadInUse(_ inUse: Bool) {
        if controllerUserInteractionEnabled == inUse { controllerUserInteractionEnabled = !inUse }
    }
}
#else
struct ScreenRepresentable: UIViewRepresentable {
    let emulator: Apple2
    let style: Screen.Style

    func makeUIView(context: Context) -> ScreenUIView {
        ScreenUIView(emulator: emulator, style: style)
    }

    func updateUIView(_ view: ScreenUIView, context: Context) {
        view.emulator = emulator
        view.style = style
    }
}
#endif

/// Runs the emulator with a display link and shows each frame's picture in
/// its layer.  Keys: a hardware keyboard's (`pressesBegan`, ⌥ the push
/// buttons), the on-screen keyboard's (`UIKeyInput`, a tap shows or hides
/// it), the Siri Remote's on tvOS.
final class ScreenUIView: UIView, UIKeyInput {
    var emulator: Apple2
    var style: Screen.Style
    private var link: CADisplayLink?

    init(emulator: Apple2, style: Screen.Style) {
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

    /// The Apple key for a press: a keyboard's, or the Siri Remote's (a
    /// control key after play/pause).
    private func ascii(for press: UIPress) -> UInt8? {
        if let key = press.key { return KeyMap.ascii(for: key, lowercase: emulator.model.isIIe) }
        #if os(tvOS)
        return KeyMap.ascii(for: press.type).map { control && $0 >= 0x40 ? $0 & 0x1F : $0 }
        #else
        return nil
        #endif
    }

    /// The Siri Remote's play/pause: Ctrl for its next key.
    private func isControl(_ press: UIPress) -> Bool {
        #if os(tvOS)
        press.key == nil && press.type == .playPause
        #else
        false
        #endif
    }

    /// Takes the presses that are Apple keys or buttons (not given to the
    /// text input then); the rest go on (⌘ shortcuts, Menu).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { press in
            if let key = press.key, let button = KeyMap.button(for: key) {
                emulator.setButton(button, pressed: true)
            } else if isControl(press) {
                pressControl(!control)
            } else if let ascii = ascii(for: press) {
                pressControl(false)
                emulator.keyDown(ascii, id: id(of: press))
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

    /// Releases the keys and buttons among `presses`; returns those that aren't ours.
    private func released(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { press in
            if let key = press.key, let button = KeyMap.button(for: key) {
                emulator.setButton(button, pressed: false)
                return false
            }
            if isControl(press) { return false }
            guard ascii(for: press) != nil else { return true }
            emulator.keyUp(id: id(of: press))
            return false
        }
    }

    /// A press's key, the same as it goes down and up: a keyboard's key
    /// code, else the remote's button.
    private func id(of press: UIPress) -> Int {
        press.key.map { $0.keyCode.rawValue } ?? 0x10000 + press.type.rawValue
    }

    // MARK: the on-screen keyboard

    /// Ctrl from the key bar (the Siri Remote's play/pause): the next key
    /// typed is a control key.
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
