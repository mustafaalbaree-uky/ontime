import SwiftUI

/// The moving half of the house style. `Shared/OnTimeSpectrum.swift` holds
/// the colours, because the widget compiles that too; everything here
/// animates, so it is app-only — a Live Activity gets the same gradient
/// standing still.
///
/// Motion is one slow rotation, driven by a single implicit SwiftUI
/// animation on a `rotationEffect` rather than a `TimelineView` redrawing
/// the whole subtree every frame. The rotation runs on the render server,
/// so it costs nothing per frame in the app process and keeps turning while
/// the rest of the screen sits idle.
private struct SpectrumSpin: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    var seconds: Double

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: seconds).repeatForever(autoreverses: false),
                       value: spinning)
            .onAppear {
                // Reduce Motion holds the same gradient still rather than
                // falling back to a flat colour: the look survives, only the
                // movement stops.
                guard !reduceMotion else { return }
                spinning = true
            }
    }
}

extension View {
    /// Turns the receiver slowly and forever. Seconds is a full turn.
    func spectrumSpin(seconds: Double = 14) -> some View {
        modifier(SpectrumSpin(seconds: seconds))
    }
}

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
    var height: CGFloat = 6

    private var remaining: Double { min(max(1 - fraction, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * remaining)
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.4), value: remaining)
        .accessibilityHidden(true)
    }
}

/// Text filled with the moving spectrum. Used on exactly one thing per
/// screen: the number the screen is about.
struct SpectrumText: View {
    var text: String
    var font: Font
    /// Late numbers are not decorated. Red means red.
    var isLate: Bool = false

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(.clear)
            .overlay {
                Group {
                    if isLate {
                        OnTimeSpectrum.late
                    } else {
                        // Deliberately far larger than the text: the gradient
                        // has to be square and oversized so that rotating it
                        // never sweeps an uncovered corner across the glyphs.
                        OnTimeSpectrum.linear()
                            .frame(width: 900, height: 900)
                            .spectrumSpin(seconds: 22)
                    }
                }
                // Load-bearing, and the whole reason the app's buttons went
                // dead. `.mask` below clips what is *drawn*; it does not clip
                // what receives touches. So this 900pt square stayed live for
                // hit testing, and inside a `Button` label it made that
                // button's tap target cover the entire screen — every tap on
                // the Now page landed on Final Time no matter what was under
                // the finger. Decoration must never be touchable.
                .allowsHitTesting(false)
            }
            .mask {
                Text(text)
                    .font(font)
                    .monospacedDigit()
            }
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

/// A card on the ink: barely-there fill, hairline edge, generous radius.
struct SpectrumCard: ViewModifier {
    var highlighted: Bool = false
    /// Defaults to the one card fill. The walk card turns it `late` at 10%
    /// once you have to turn around, which is the only place a card's fill
    /// carries a state.
    var fill: Color = OnTimeSpectrum.surface

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                // A plain white edge, not a spectrum one. The rainbow border
                // marked the current step during a run, on a screen whose
                // whole job is to be readable at a glance while you are busy
                // doing the step it is describing.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(highlighted ? Color.white.opacity(0.45) : Color.white.opacity(0.12),
                                  lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

extension View {
    func spectrumCard(highlighted: Bool = false,
                      fill: Color = OnTimeSpectrum.surface) -> some View {
        modifier(SpectrumCard(highlighted: highlighted, fill: fill))
    }

    /// The app's ground. Applied once per screen.
    func spectrumBackground() -> some View {
        background(OnTimeSpectrum.ink.ignoresSafeArea())
    }
}

/// A button on the ink: a lifted plate with a plain white edge, brighter for
/// the affirmative one.
///
/// It does **not** wear the spectrum, and that is the correction to a pass
/// that put a rainbow border on every button on the screen. One rainbow per
/// screen means one: the Final Time number on the composer, the ring on a
/// live run. A gradient on the Start button, the Steps button, the Stop
/// button, the "+" and the shortcut chips all at once is not more of the
/// look, it is the end of it — nothing is emphasised when everything is, and
/// the colour stops being able to mean anything.
struct SpectrumButtonStyle: ButtonStyle {
    var prominent: Bool = true
    /// Overrides the plain white edge. Only the walk card uses it, to put
    /// `late` around Heading Back once you are past the turnaround.
    var edge: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(prominent ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(edge ?? Color.white.opacity(prominent ? 0.38 : 0.14),
                                  lineWidth: prominent ? 1.5 : 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
