#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The host's keys as the Apple's keyboard: ASCII 0-127 (`Apple2.press`).
enum KeyMap {
    /// The Apple key for a typed character (`characters` as the layout has
    /// it, ⌥ included: [ ] @ \ | are ⌥ keys on some layouts); nil: not one.
    /// With `control`, Ctrl-@ … Ctrl-_ from the key without modifiers.
    /// `lowercase`: the //e's keyboard (else capitals, as the ][ and ][+ type).
    static func ascii(characters: String?, ignoringModifiers: String?, control: Bool, lowercase: Bool) -> UInt8? {
        guard let scalar = (control ? ignoringModifiers : characters)?.unicodeScalars.first,
              scalar.isASCII else { return nil }
        var c = UInt8(scalar.value)
        if !lowercase || control, (0x61 ... 0x7A).contains(c) { c -= 0x20 }
        if control {
            guard (0x40 ... 0x5F).contains(c) else { return nil }
            return c & 0x1F
        }
        return c
    }

    /// The special keys: return, delete and ← (the ][+'s backspace), →,
    /// ↑ and ↓ (Ctrl-K and Ctrl-J, as on the //e), esc, tab (Ctrl-I).
    static let returnKey: UInt8 = 0x0D, left: UInt8 = 0x08, right: UInt8 = 0x15
    static let up: UInt8 = 0x0B, down: UInt8 = 0x0A, escape: UInt8 = 0x1B, tab: UInt8 = 0x09

    #if os(macOS)
    /// The Apple key for a key press; nil: not one (⌘ shortcuts go to the menus).
    static func ascii(for event: NSEvent, lowercase: Bool = false) -> UInt8? {
        let flags = event.modifierFlags
        if flags.contains(.command) { return nil }
        switch event.keyCode {
        case 36, 76: return returnKey           // return, enter
        case 51, 123: return left               // delete, ←
        case 124: return right
        case 126: return up
        case 125: return down
        case 53: return escape
        case 48: return tab
        default: break
        }
        return ascii(characters: event.characters, ignoringModifiers: event.charactersIgnoringModifiers,
                     control: flags.contains(.control), lowercase: lowercase)
    }

    /// The left and right ⌥ as the push buttons 0 and 1 (open and solid
    /// apple), by key code.
    static let buttonKeys: [UInt16: Int] = [58: 0, 61: 1]
    #endif

    #if canImport(UIKit) && !os(watchOS)
    /// The Apple key for a hardware keyboard's key; nil: not one (⌘
    /// shortcuts go to the key commands).  On tvOS esc is Back (the remote's
    /// Menu; the Simulator's remote sends it too): Ctrl-[ is the Apple's ESC.
    static func ascii(for key: UIKey, lowercase: Bool = false) -> UInt8? {
        let flags = key.modifierFlags
        if flags.contains(.command) { return nil }
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: return returnKey
        case .keyboardDeleteOrBackspace, .keyboardLeftArrow: return left
        case .keyboardRightArrow: return right
        case .keyboardUpArrow: return up
        case .keyboardDownArrow: return down
        #if os(tvOS)
        case .keyboardEscape where !flags.contains(.control): return nil   // Back, as the remote's Menu
        #else
        case .keyboardEscape: return escape
        #endif
        case .keyboardTab: return tab
        default: break
        }
        return ascii(characters: key.characters, ignoringModifiers: key.charactersIgnoringModifiers,
                     control: flags.contains(.control), lowercase: lowercase)
    }

    /// The left and right ⌥ (alt) as the push buttons 0 and 1.
    static func button(for key: UIKey) -> Int? {
        switch key.keyCode {
        case .keyboardLeftAlt: 0
        case .keyboardRightAlt: 1
        default: nil
        }
    }

    #if os(tvOS)
    /// The Siri Remote as many games' keys: the arrows as I, J, K, M (up,
    /// left, right, down), select as space.  Play/pause isn't one (it is
    /// Ctrl for the next of these: `ScreenUIView`), nor Menu (it goes back).
    static func ascii(for press: UIPress.PressType) -> UInt8? {
        switch press {
        case .upArrow: 0x49             // I
        case .leftArrow: 0x4A           // J
        case .rightArrow: 0x4B          // K
        case .downArrow: 0x4D           // M
        case .select: 0x20
        default: nil
        }
    }
    #endif
    #endif
}
