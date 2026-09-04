import SwiftUI
import UIKit

/// The draggable "chevron capsule" behind `DurationScrubber`, pulled out so
/// other value-scrubbing controls (the Final Time picker's time-of-day
/// scrub) can reuse the exact same drag-to-scrub feel instead of
/// duplicating the gesture math.
///
/// Drag left/right adjusts `value` one unit at a time, with a selection
/// haptic on each change. `scrubWindow`, when set, caps how far a single
/// drag can move `value` away from wherever it started — past that, a
/// release calls `onExceedWindow` instead of clamping, so the caller can
/// hand off to a typed-entry prompt for a big jump. `nil` means no window:
/// clamp to `range` and never hand off.
struct ScrubTrack: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var scrubWindow: Int? = nil
    var pointsPerValue: CGFloat = 10
    var onExceedWindow: ((Int) -> Void)? = nil

    @State private var isDragging = false
    @State private var dragStartValue = 0
    @State private var lastHapticValue = 0

    var body: some View {
        ZStack {
            Capsule()
                .fill(isDragging ? OnTimeSpectrum.surfaceRaised : OnTimeSpectrum.surface)
                .overlay(Capsule().strokeBorder(OnTimeSpectrum.hairline, lineWidth: 1))
            HStack {
                Image(systemName: "chevron.left")
                Spacer()
                Image(systemName: "chevron.right")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(isDragging ? OnTimeSpectrum.secondaryText : OnTimeSpectrum.tertiaryText)
            .padding(.horizontal, 14)
        }
        .frame(height: 40)
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        dragStartValue = value
                        lastHapticValue = value
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    let rawTarget = dragStartValue + Int((drag.translation.width / pointsPerValue).rounded())
                    let clamped = rawTarget.clamped(to: windowRange)
                    if clamped != value {
                        value = clamped
                        if clamped != lastHapticValue {
                            UISelectionFeedbackGenerator().selectionChanged()
                            lastHapticValue = clamped
                        }
                    }
                }
                .onEnded { drag in
                    isDragging = false
                    guard scrubWindow != nil else { return }
                    let rawTarget = dragStartValue + Int((drag.translation.width / pointsPerValue).rounded())
                    if rawTarget < windowRange.lowerBound || rawTarget > windowRange.upperBound {
                        onExceedWindow?(rawTarget.clamped(to: range))
                    }
                }
        )
    }

    private var windowRange: ClosedRange<Int> {
        guard let window = scrubWindow else { return range }
        let lower = max(range.lowerBound, dragStartValue - window)
        let upper = min(range.upperBound, dragStartValue + window)
        return lower...upper
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
