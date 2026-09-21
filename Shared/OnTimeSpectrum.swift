import SwiftUI

/// The app's one piece of visual vocabulary, compiled into both the app and
/// the widget extension so the Live Activity and the screen it mirrors
/// cannot drift into two different-looking products.
///
/// The ground is true black, content sits on it as filled surfaces with no
/// outline, and three whites carry the whole hierarchy. Colour is a signal:
/// `late`, `done` and `waiting`, plus `accent` on a toggle track. The
/// spectrum survives in exactly one place, the Final Time number on the
/// composer, which is why `wheel` and `linear` are still here and the ring,
/// ramp and per step hue are not.
///
/// This is look A, "Instrument", chosen from three mockups on 21 Sep 2026.
/// What it replaced was SF Rounded in bold and heavy, an outline on every
/// box, 18 pt corners and tracked capital labels, which the owner found toy
/// like. Look A is SF Pro at regular weight, thin large numerals like the
/// Clock app, filled dark surfaces, 10 pt corners and sentence case.
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

    /// Card fill, #121315: a filled plate on the black ground. A card has
    /// no stroke; the fill alone is what separates it from the ink.
    public static let surface = Color(red: 0x12 / 255.0, green: 0x13 / 255.0, blue: 0x15 / 255.0)

    /// One step up, #1F2023: small controls that sit on a card (the stepper's
    /// minus and plus, a chip inside a card), the quiet button, the current
    /// step's row during a run, a scrub track while it is being dragged.
    public static let surfaceRaised = Color(red: 0x1F / 255.0, green: 0x20 / 255.0, blue: 0x23 / 255.0)

    /// The 1 px rule between two rows of the same card.
    public static let rule = Color.white.opacity(0.07)

    /// A line drawn straight on the black ground: over the tab bar, over a
    /// pinned bottom bar. Brighter than `rule` because it has no surface
    /// under it to stand against.
    public static let hairline = Color.white.opacity(0.12)

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
    ///
    /// It is the iOS system green, so a switch reads as the native one. Never
    /// text, never an icon.
    public static let accent = Color.green

    /// Meaning colours. Late is the one that must never be mistaken for
    /// decoration, so it is a flat unambiguous red and the spectrum yields
    /// to it everywhere.
    public static let late = Color(red: 1.0, green: 0.27, blue: 0.29)
    public static let done = Color(red: 0.29, green: 0.92, blue: 0.55)
    public static let waiting = Color(red: 1.0, green: 0.72, blue: 0.22)

    // MARK: - Numerals

    /// The font for a number that is the point of its screen: the Final Time,
    /// a countdown, a week total. Thin from 36 pt up, light from 24 pt, and
    /// regular below that, where thin strokes stop being legible. SF Pro, the
    /// default design, never rounded. It lives here rather than in the app's
    /// `InkType` so the Live Activity and the widget set their numbers with
    /// the same rule the phone does. Pair it with `monospacedDigit()`.
    public static func numeral(_ size: CGFloat) -> Font {
        let weight: Font.Weight = size >= 36 ? .thin : (size >= 24 ? .light : .regular)
        return .system(size: size, weight: weight)
    }

    /// Large numerals sit slightly tight, about 0.02 em. Nothing under 24 pt
    /// is tightened.
    public static func numeralTracking(_ size: CGFloat) -> CGFloat {
        size >= 24 ? -0.02 * size : 0
    }
}

public extension View {
    /// Sets a large number the one way the product sets them: `numeral`'s
    /// weight for the size, fixed width digits so a countdown does not
    /// shuffle sideways as it ticks, and the tight tracking.
    func onTimeNumeral(_ size: CGFloat) -> some View {
        font(OnTimeSpectrum.numeral(size))
            .monospacedDigit()
            .tracking(OnTimeSpectrum.numeralTracking(size))
    }
}
