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
///
/// With the mouse card in (not on tvOS), the touches and the pointer are the
/// mouse: a finger or the pointer moved moves it, a tap or click clicks, a
/// touch held then moved – or a click held – drags (the button down); a
/// two-finger tap shows or hides the on-screen keyboard.  The pointer is
/// hidden over the screen, the Apple's own showing.
final class ScreenUIView: UIView, UIKeyInput {
    var emulator: Apple2
    var style: Screen.Style
    private var link: CADisplayLink?
    #if !os(tvOS)
    /// The pan's touch is the pointer's, a click held: the button down.
    private var panHoldsButton = false
    /// Where the hover, or the held touch, was last (the view's points).
    private var lastHover: CGPoint?
    private var lastHold: CGPoint?
    /// `emulator.mouse` as the pointer's style was last set.
    private var mouseShown = false
    #if os(iOS)
    private var pointer: UIPointerInteraction?
    #endif
    #endif

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
        addMouseGestures()
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
        #if !os(tvOS)
        if mouseShown != emulator.mouse { mouseCardChanged() }
        #endif
        if let image = emulator.frame(at: link.targetTimestamp, style: style) { layer.contents = image }
    }

    @objc private func toggleKeyboard() {
        if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() }
    }

    override var canBecomeFirstResponder: Bool { true }
    #if os(tvOS)
    override var canBecomeFocused: Bool { true }
    #endif

    #if !os(tvOS)
    // MARK: the mouse

    private func addMouseGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(toggleKeyboard))
        twoFingerTap.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.4
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: hold)               // a touch held is a drag
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        for recognizer in [hold, pan, hover] { recognizer.delegate = self }
        for recognizer in [tap, twoFingerTap, hold, pan, hover] { addGestureRecognizer(recognizer) }
        #if os(iOS)
        let pointer = UIPointerInteraction(delegate: self)
        addInteraction(pointer)
        self.pointer = pointer
        #endif
    }

    /// The card put in or taken out: the pointer shown or hidden, the button up.
    private func mouseCardChanged() {
        mouseShown = emulator.mouse
        lastHover = nil
        lastHold = nil
        #if os(iOS)
        pointer?.invalidate()
        #endif
    }

    /// A tap: a click with the mouse card in, else the on-screen keyboard.
    @objc private func tapped() {
        if emulator.mouse { emulator.clickMouse() } else { toggleKeyboard() }
    }

    /// A finger, or the pointer with its button held, moved.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            if panHoldsButton { emulator.mouseButton(down: true) }
            fallthrough
        case .changed:
            move(by: pan.translation(in: self))
            pan.setTranslation(.zero, in: self)
        default:
            if panHoldsButton { emulator.mouseButton(down: false) }
        }
    }

    /// A touch held: the button down, a drag as it moves, up as it lifts.
    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: self)
        switch hold.state {
        case .began:
            lastHold = point
            emulator.mouseButton(down: true)
        case .changed:
            if let last = lastHold { move(by: CGPoint(x: point.x - last.x, y: point.y - last.y)) }
            lastHold = point
        default:
            lastHold = nil
            emulator.mouseButton(down: false)
        }
    }

    /// The pointer moved over the screen, no button held.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        let point = hover.location(in: self)
        switch hover.state {
        case .began:
            lastHover = point
        case .changed:
            if let last = lastHover { move(by: CGPoint(x: point.x - last.x, y: point.y - last.y)) }
            lastHover = point
        default:
            lastHover = nil
        }
    }

    /// A movement in the view's points, as far on the Apple's screen as
    /// on the view: 280 counts across it.
    private func move(by delta: CGPoint) {
        guard bounds.width > 0 else { return }
        let scale = 280 / bounds.width
        emulator.moveMouse(dx: delta.x * scale, dy: delta.y * scale)
    }
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

#if !os(tvOS)
extension ScreenUIView: UIGestureRecognizerDelegate {
    /// The mouse's gestures only while the card is in.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer.delegate === self { return emulator.mouse }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer is UIPanGestureRecognizer { panHoldsButton = touch.type == .indirectPointer }
        return true
    }
}
#endif

#if os(iOS)
extension ScreenUIView: UIPointerInteractionDelegate {
    /// Hidden over the screen while the card is in: the Apple shows its own.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        emulator.mouse ? .hidden() : nil
    }
}
#endif
#endif
