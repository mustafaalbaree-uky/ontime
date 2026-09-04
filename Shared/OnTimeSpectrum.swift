import SwiftUI

/// The app's one piece of visual vocabulary, compiled into both the app and
/// the widget extension so the Live Activity and the screen it mirrors
/// cannot drift into two different-looking products.
///
/// The ground is true black, content sits on it as hairline cards, and three
/// whites carry the whole hierarchy. Colour is a signal: `late`, `done` and
/// `waiting`, plus `accent` on a toggle track. The spectrum survives in
/// exactly one place, the Final Time number on the composer, which is why
/// `wheel` and `linear` are still here and the ring, ramp and per step hue
/// are not.
public enum OnTimeSpectrum {

    /// One full turn of hue, doubled so the ring closes on itself without a
    /// visible seam where red meets red.
    public static func wheel(rotation: Double = 0, saturation: Double = 0.85,
                             brightness: Double = 1.0, opacity: Double = 1.0) -> Gradient {
        let count = 12
        let stops = (0...count).map { i -> Gradient.Stop in
            let t = Double(i) / Double(count)
            let hue = (t + rotation).truncatingRemainder(dividingBy: 1.0)
            return Gradient.Stop(
                color: Color(hue: hue, saturation: saturation, brightness: brightness).opacity(opacity),
                location: t
            )
        }
        return Gradient(stops: stops)
    }

    /// The spectrum as a left-to-right sweep, for text fills, borders and bars.
    public static func linear(rotation: Double = 0, opacity: Double = 1.0) -> LinearGradient {
        LinearGradient(gradient: wheel(rotation: rotation, opacity: opacity),
                       startPoint: .leading,
                       endPoint: .trailing)
    }

    /// The ground everything is drawn on. True black, not `systemBackground`:
    /// on an OLED phone it is the only background that makes a spectrum look
    /// like it is emitting rather than printed.
    public static let ink = Color.black

    /// Card fill: barely lifted off the ink so an edge is findable without
    /// becoming grey.
    public static let surface = Color.white.opacity(0.06)

    /// A card fill lifted one more step: the prominent button, the scrub
    /// track while it is being dragged, a list row's swipe plate.
    public static let surfaceRaised = Color.white.opacity(0.10)

    public static let hairline = Color.white.opacity(0.12)

    /// The two brighter edges. `edge` outlines the "+" circle and the Add
    /// chip; `edgeStrong` outlines a prominent button.
    public static let edge = Color.white.opacity(0.28)
    public static let edgeStrong = Color.white.opacity(0.38)

    public static let primaryText = Color.white
    public static let secondaryText = Color.white.opacity(0.62)
    public static let tertiaryText = Color.white.opacity(0.38)

    /// The tint for *system* controls: toggles, pickers, the tab bar's
    /// selected item, a `DatePicker`'s highlighted value.
    ///
    /// It exists because the obvious choice, tinting the app white to match
    /// the palette, is unusable. A `Toggle` draws its on state by filling the
    /// track with the tint and its knob in white, so a white tint makes on
    /// and off both read as a pale capsule with a white circle in it — every
    /// switch in Settings looked identical regardless of its value. A tint
    /// has to be a colour the control can be *seen* to be wearing, which
    /// means not white and not the background.
    public static let accent = Color(hue: 0.55, saturation: 0.9, brightness: 1.0)

    /// Meaning colours. Late is the one that must never be mistaken for
    /// decoration, so it is a flat unambiguous red and the spectrum yields
    /// to it everywhere.
    public static let late = Color(red: 1.0, green: 0.27, blue: 0.29)
    public static let done = Color(red: 0.29, green: 0.92, blue: 0.55)
    public static let waiting = Color(red: 1.0, green: 0.72, blue: 0.22)
}
