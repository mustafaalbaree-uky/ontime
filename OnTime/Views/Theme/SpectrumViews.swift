import SwiftUI

/// The card, the button style, the time bar and the page dots.
///
/// This file used to hold the app's one animated piece, `SpectrumText`: a
/// slowly rotating rainbow fill on the composer's Final Time number, with the
/// `SpectrumSpin` modifier that turned it. He asked for the rainbow numbers
/// gone on 21 Sep 2026 and nothing else used either, so both are deleted
/// rather than left where a later change could reach for them. Nothing in the
/// product is spectrum filled. The names `spectrumCard` and
/// `SpectrumButtonStyle` are history, not a description.
///
/// One lesson from `SpectrumText` outlives it: `.mask` and `.blur` clip what
/// is drawn, not what receives touches. Its 900 pt gradient, masked to the
/// glyphs, stayed a 900 pt tap target inside the Final Time button and
/// swallowed every tap on the Now page. Any decoration larger than the thing
/// it decorates needs `.allowsHitTesting(false)`.

/// A flat horizontal gauge: how much of a span is left, drawn left to right.
///
/// This is what replaced `SpectrumRing` on the live run page. The ring was
/// the app's loudest piece of decoration and it was carrying almost no
/// information — a rotating rainbow around a number that already said the
/// same thing in digits. A run in progress is the screen you look at while
/// doing something else, so it is the one screen that should be quiet: one
/// number, one line under it, and colour only where colour means something.
///
/// `fraction` is elapsed, matching `OnTimeActivityLogic.spanFraction`, so 0
/// is a full bar and 1 is an empty one.
struct TimeBar: View {
    var fraction: Double
    /// White while the span is running; the flat `late` red once it is not.
    /// Nothing else, deliberately — a green-to-red ramp here would be a
    /// second signal saying what the number already says.
    var tint: Color = OnTimeSpectrum.primaryText
    var height: CGFloat = InkMetric.pipHeight

    private var remaining: Double { min(max(1 - fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle()
                    .fill(tint)
                    .frame(width: proxy.size.width * remaining)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
        .animation(.easeInOut(duration: 0.4), value: remaining)
        .accessibilityHidden(true)
    }
}

/// The page indicator, in the shape the iPhone Home Screen uses: one dot per
/// page, the current one lit. Lit is plain white, because the composer's
/// Final Time number is the one spectrum element in the product and two of
/// them on the same screen is the point at which neither means anything.
/// Deliberately renders nothing at all for a single page, because a single
/// dot is a control that says nothing.
struct SpectrumPageDots: View {
    var count: Int
    var index: Int

    var body: some View {
        if count > 1 {
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(i == index ? 0.95 : 0.22))
                        .frame(width: 7, height: 7)
                        .frame(width: 8, height: 8)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: index)
            .accessibilityElement()
            .accessibilityLabel("Page \(index + 1) of \(count)")
        }
    }
}

/// A card on the ink: a filled surface with a 10 pt corner and no stroke.
///
/// It was a barely there fill inside a hairline outline with an 18 pt corner,
/// and the outline on every box was half of what made the app read as a toy.
/// The fill alone separates a card from the black now. `highlighted` is gone
/// with the outline it brightened: the current step marks itself with
/// `surfaceRaised` instead (see `StepRowCard`).
struct SpectrumCard: ViewModifier {
    /// Defaults to the one card fill. The walk card turns it `late` at 10%
    /// once you have to turn around, and the current step's row passes
    /// `surfaceRaised`; nothing else changes a card's fill.
    var fill: Color = OnTimeSpectrum.surface

    func body(content: Content) -> some View {
        content
            .environment(\.inkOnCard, true)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: InkMetric.radius, style: .continuous))
    }
}

extension View {
    func spectrumCard(fill: Color = OnTimeSpectrum.surface) -> some View {
        modifier(SpectrumCard(fill: fill))
    }

    /// The app's ground. Applied once per screen.
    func spectrumBackground() -> some View {
        background(OnTimeSpectrum.ink.ignoresSafeArea())
    }
}

/// A button on the ink. The affirmative one is a white plate with black text
/// at medium weight; the quiet one is the raised surface with white text.
/// Neither has an outline, and both press in slightly.
///
/// The style sets the label's colour, so a call site must not put its own
/// white `foregroundStyle` on a prominent button's label: that is white text
/// on a white plate. Secondary text inside a prominent label is
/// `OnTimeSpectrum.ink` at an opacity, not one of the three whites.
///
/// It does **not** wear the spectrum, and that is the correction to a pass
/// that put a rainbow border on every button on the screen. The Final Time
/// number on the composer is the one spectrum element in the product; a
/// gradient on the Start button, the Steps button, the Stop button, the "+"
/// and the shortcut chips all at once is not more of the look, it is the end
/// of it. Nothing is emphasised when everything is.
struct SpectrumButtonStyle: ButtonStyle {
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? InkType.buttonProminent : InkType.buttonQuiet)
            .foregroundStyle(prominent ? OnTimeSpectrum.ink : OnTimeSpectrum.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(prominent ? OnTimeSpectrum.primaryText : OnTimeSpectrum.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: InkMetric.radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
