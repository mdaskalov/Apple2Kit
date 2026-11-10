#if canImport(GameController) && !os(watchOS)
import GameController
#endif

/// A game controller as the Apple's joystick (`GamePort.Joystick`): the left
/// stick, or the d-pad, as paddles 0 and 1, A or X as button 0 and B or Y
/// as button 1.  The controller used last plays.  `Apple2` reads it every
/// display frame; a host running its own `Apple2Machine` calls
/// `readGameController` as often.
public enum GameControllers {
    /// The controller in use: its name and the joystick it is; nil: none
    /// connected (or none on the platform: watchOS).
    public static func read() -> (name: String, joystick: GamePort.Joystick)? {
        #if canImport(GameController) && !os(watchOS)
        // the current one if it is a gamepad, else any that is: on tvOS the
        // Siri Remote is a controller too (micro gamepad only), often current
        let current = GCController.current.flatMap { $0.extendedGamepad != nil ? $0 : nil }
        guard let controller = current ?? GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let pad = controller.extendedGamepad
        else { return nil }
        let dpad = pad.dpad
        let stick = dpad.xAxis.value != 0 || dpad.yAxis.value != 0 ? dpad : pad.leftThumbstick
        let (x, y) = paddles(x: stick.xAxis.value, y: stick.yAxis.value)
        return (controller.vendorName ?? "Game controller",
                GamePort.Joystick(x: x, y: y, buttons: [pad.buttonA.isPressed || pad.buttonX.isPressed,
                                                        pad.buttonB.isPressed || pad.buttonY.isPressed]))
        #else
        return nil
        #endif
    }

    /// The paddle positions (0-255, 128 in the middle, y growing downwards)
    /// for a stick at (x, y), -1...1 each, y up: its round gate stretched to
    /// the Apple joystick's square one, so a corner is all the way both ways
    /// (as AppleWin squares the circle).  Within `deadZone` it is the
    /// middle: the noise of a stick let go would move the paddles.
    public static func paddles(x: Float, y: Float) -> (x: UInt8, y: UInt8) {
        let r = min((x * x + y * y).squareRoot(), 1)
        guard r >= deadZone else { return (128, 128) }
        let stretch = r / max(abs(x), abs(y))
        func paddle(_ v: Float) -> UInt8 { UInt8(((min(max(v * stretch, -1), 1) + 1) * 127.5).rounded()) }
        return (paddle(x), paddle(-y))
    }

    /// A fifth of the way out.
    public static let deadZone: Float = 0.2
}

public nonisolated extension Apple2Machine {
    /// The game controller as the joystick (`GameControllers`): plugged in
    /// once one is connected, its stick and buttons while `playing`, else
    /// let go.  When it goes, the joystick stays plugged in, let go: a
    /// program reads one unplugged as all the way right and down.  Returns
    /// the controller's name; nil: none connected.
    @MainActor @discardableResult
    func readGameController(playing: Bool = true) -> String? {
        let controller = GameControllers.read()
        guard controller != nil || gamePort.joystick != nil else { return nil }
        let joystick = playing ? controller?.joystick ?? .centre : .centre
        if gamePort.joystick != joystick { gamePort.joystick = joystick }
        return controller?.name
    }
}
