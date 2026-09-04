import SwiftUI
import UIKit

/// Replaces a plain `Stepper(step: 5)` for entering a duration in minutes.
/// Drag left/right to scrub the value one minute at a time (video-scrubber
/// feel, with a selection tick each time the value changes) for anything
/// within 30 minutes of wherever the drag started; drag past that and it
/// hands off to a typed entry prompt pre-filled with where you dragged to,
/// since scrubbing stops being the fast way to reach "127" but typing still
/// is. The keyboard button next to it opens the same typed-entry prompt
/// directly, for exact or large values. Drag mechanics live in `ScrubTrack`,
/// shared with the Final Time picker's time-of-day scrub.
struct DurationScrubber: View {
    @Binding var minutes: Int
    var range: ClosedRange<Int> = 1...300
    private let scrubWindow = 30
    private let pointsPerMinute: CGFloat = 10

    @State private var showingTypePrompt = false
    @State private var typedText = ""

    var body: some View {
        HStack(spacing: 10) {
            Text("\(minutes) min")
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(OnTimeSpectrum.primaryText)
                .frame(minWidth: 64, alignment: .leading)
                .contentTransition(.numericText())
                .animation(.default, value: minutes)

            ScrubTrack(
                value: $minutes,
                range: range,
                scrubWindow: scrubWindow,
                pointsPerValue: pointsPerMinute
            ) { target in
                typedText = "\(target)"
                showingTypePrompt = true
            }

            Button {
                typedText = "\(minutes)"
                showingTypePrompt = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.subheadline)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .alert("Minutes", isPresented: $showingTypePrompt) {
            TextField("Minutes", text: $typedText)
                .keyboardType(.numberPad)
            Button("Set") {
                if let value = Int(typedText) {
                    minutes = value.clamped(to: range)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
