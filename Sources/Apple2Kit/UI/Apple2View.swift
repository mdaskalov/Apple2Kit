import SwiftUI

/// The Apple's screen, running `emulator` frame by frame with the display
/// and taking the keys while it has the focus.
///
/// * macOS: the keyboard; a click gives it the focus back.  Left and right
///   ⌥ are the push buttons.
/// * iOS, iPadOS, visionOS: a hardware keyboard (as the Mac's), else a tap
///   brings up the on-screen keyboard with a bar of the keys it lacks (esc,
///   ctrl, the arrows); a tap again hides it.
/// * tvOS: a hardware keyboard, and the Siri Remote: the arrows, select
///   (return), play/pause (space).
/// * watchOS: the screen only; keys through `EmulatorModel.press`/`type`.
///
/// `style`: how the screen is coloured (Color, Color Filled, Mono).
/// `scale`: the Apple's 280 × 192 dots at that many points each (1, 2, 3…);
/// nil: any size the view is given, the picture fitted in it at the
/// screen's aspect ratio (280:192).
public struct Apple2View: View {
    let emulator: EmulatorModel
    let style: Screen.Style
    let scale: CGFloat?

    public init(_ emulator: EmulatorModel, style: Screen.Style = .color, scale: CGFloat? = nil) {
        self.emulator = emulator
        self.style = style
        self.scale = scale
    }

    public var body: some View {
        ScreenRepresentable(emulator: emulator, style: style)
            .aspectRatio(CGSize(width: 280, height: 192), contentMode: .fit)
            .frame(width: scale.map { 280 * $0 }, height: scale.map { 192 * $0 })
    }
}

#if os(watchOS)
/// The screen redrawn with the display (`TimelineView`), each frame running
/// the machine up to it.
private struct ScreenRepresentable: View {
    let emulator: EmulatorModel
    let style: Screen.Style

    var body: some View {
        TimelineView(.animation) { _ in
            if let image = emulator.frame(at: mediaTime(), style: style) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)       // 560 × 192 dots on a 280:192 view
            } else {
                Color.black
            }
        }
        .background(.black)
    }
}
#endif
