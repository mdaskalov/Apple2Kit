import SwiftUI

/// The Apple's screen, running an `Apple2` frame by frame with the display
/// and taking the keys while it has the focus.
///
/// * macOS: the keyboard; a click gives it the focus back.  Left and right
///   ⌥ are the push buttons.
/// * iOS, iPadOS, visionOS: a hardware keyboard (as the Mac's), else a tap
///   brings up the on-screen keyboard with a bar of the keys it lacks (esc,
///   ctrl, the arrows); a tap again hides it.
/// * tvOS: a hardware keyboard, and the Siri Remote: the arrows, select
///   (return), play/pause (space).
/// * watchOS: the screen only; keys through `Apple2.press`/`type`.
///
/// `style`: how the screen is coloured (Color, Color Filled, Mono).
/// `scale`: the Apple's 280 × 192 dots at that many points each (1, 2, 3…);
/// nil: any size the view is given, the picture fitted in it at the
/// screen's aspect ratio (280:192).
public struct Apple2View: View {
    private let style: Screen.Style
    private let scale: CGFloat?
    /// The app's (`init(_:style:scale:)`), else the view's own.
    private let given: Apple2?
    private let model: Apple2.Model
    private let roms: ROMs.Source
    private let setup: ((Apple2) -> Void)?
    @State private var owned: Apple2?

    /// Shows `apple`, which the app holds (`@State`) to work it later: keys,
    /// disks, pause, status.
    public init(_ apple: Apple2, style: Screen.Style = .color, scale: CGFloat? = nil) {
        self.given = apple
        self.model = apple.model
        self.roms = apple.roms
        self.setup = nil
        self.style = style
        self.scale = scale
    }

    /// A machine of the view's own (`Apple2(model:roms:)`), made once, when
    /// the view first appears, and `setup` run on it then: disks in, a
    /// program loaded, text printed…  It lives as long as the view.
    public init(_ model: Apple2.Model = .apple2Plus, roms: ROMs.Source = .bundle, style: Screen.Style = .color,
                scale: CGFloat? = nil, setup: ((Apple2) -> Void)? = nil) {
        self.given = nil
        self.model = model
        self.roms = roms
        self.setup = setup
        self.style = style
        self.scale = scale
    }

    public var body: some View {
        Group {
            if let apple = given ?? owned {
                ScreenRepresentable(emulator: apple, style: style)
            } else {
                Color.black
            }
        }
        .aspectRatio(CGSize(width: 280, height: 192), contentMode: .fit)
        .frame(width: scale.map { 280 * $0 }, height: scale.map { 192 * $0 })
        .onAppear {
            guard given == nil, owned == nil else { return }
            let apple = Apple2(model: model, roms: roms)
            setup?(apple)
            owned = apple
        }
    }
}

#if os(watchOS)
/// The screen redrawn with the display (`TimelineView`), each frame running
/// the machine up to it.
private struct ScreenRepresentable: View {
    let emulator: Apple2
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
