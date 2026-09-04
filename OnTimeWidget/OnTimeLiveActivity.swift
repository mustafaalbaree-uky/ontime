import ActivityKit
import SwiftUI
import WidgetKit

/// Phase resolution, the ring's span guard, the late range and the
/// over-state caption all live in `Shared/OnTimeActivityLogic.swift` — pure
/// functions both targets compile, so the app's test target can pin them
/// down. `RunPhase` here is just a local name for the shared enum.
private typealias RunPhase = OnTimeActivityPhase

// MARK: - What a Live Activity can and cannot do
//
// Two system views animate on their own inside a Live Activity:
// `Text(timerInterval:)` and `ProgressView(timerInterval:)`. Nothing else
// does. The app is suspended for most of a run, so any hand-drawn motion
// (and any gradient that would need re-pushing to appear to move) freezes at
// whatever was last sent.
//
// So this plate is monochrome, the same three whites the Home Screen widget
// and the run page use: 0.95 for the step you are on, 0.30 for the ones
// behind it, 0.12 for the ones ahead. The one thing that must keep moving
// without the app, the ring, stays a `ProgressView(timerInterval:)` and is
// tinted white; colour on it is reserved for late and finished, which are
// states rather than decoration.

private extension OnTimeActivityAttributes.ContentState {
    var ringInterval: ClosedRange<Date>? {
        OnTimeActivityLogic.ringInterval(segmentStart: segmentStart, targetLeaveBy: targetLeaveBy)
    }

    var lateInterval: ClosedRange<Date> {
        OnTimeActivityLogic.lateInterval(target: targetLeaveBy)
    }

    var overCaption: String {
        OnTimeActivityLogic.overCaption(
            latenessMinutes: latenessMinutes,
            isWaiting: isWaiting,
            startsRunAtTarget: startsRunAtTarget
        )
    }

    /// `targetLabel` arrives with a trailing space by convention; enforcing
    /// the separator here means a future label without one renders as
    /// "Finish by 7:15" instead of "Finish by7:15".
    var normalizedTargetLabel: String {
        targetLabel.trimmingCharacters(in: .whitespaces) + " "
    }

    var glyph: String {
        isWaiting ? "hourglass" : symbol
    }
}

/// The countdown, in the only two forms it is ever allowed to take.
///
/// Running: counts down and stops at 0:00, because a `Text(timerInterval:)`
/// built from a *range* clamps at both of that range's ends on its own. Over:
/// counts up from the target, in red, behind an explicit plus sign so it can
/// never be mistaken for the countdown it just replaced.
///
/// The clamping is the whole reason this uses the range form rather than
/// `Text(_:style: .timer)`, which free-runs past its date and starts climbing
/// unannounced. Do **not** reach for `pauseTime` to get the clamp: passing it
/// renders the timer as *paused* rather than as running-until-paused, so the
/// number froze on the Lock Screen and never counted at all. The range alone
/// is the fix.
private struct CountdownNumber: View {
    let state: OnTimeActivityAttributes.ContentState
    let phase: RunPhase
    let size: CGFloat

    private var font: Font { .system(size: size, weight: .bold, design: .rounded) }

    var body: some View {
        switch phase {
        case .finished:
            Text("Done")
                .font(font)
                .foregroundStyle(OnTimeSpectrum.done)
        case .over:
            HStack(spacing: 0) {
                Text("+")
                    .font(.system(size: size * 0.7, weight: .bold, design: .rounded))
                Text(timerInterval: state.lateInterval, countsDown: false)
                    .font(font)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            .foregroundStyle(OnTimeSpectrum.late)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
        case .running:
            Group {
                if let interval = state.ringInterval {
                    Text(timerInterval: interval, countsDown: true)
                } else {
                    Text("0:00")
                }
            }
            .font(font)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(OnTimeSpectrum.primaryText)
        }
    }
}

/// The run's progress as a row of pips, one per step: the current one lit and
/// taller, the ones behind it dimmer, the ones ahead dimmest. The same three
/// whites as the Home Screen widget and the run page, so the phone and the
/// Lock Screen say the same thing in the same way.
private struct StepPips: View {
    let state: OnTimeActivityAttributes.ContentState
    let phase: RunPhase

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(state.totalBlocks, 1), id: \.self) { i in
                let passed = phase == .finished || i < state.blockIndex
                let current = phase != .finished && i == state.blockIndex
                Capsule()
                    .fill(current ? Color.white.opacity(0.95)
                          : (passed ? Color.white.opacity(0.30) : Color.white.opacity(0.12)))
                    .frame(height: current ? 6 : 4)
            }
        }
        .frame(height: 6)
    }
}

struct OnTimeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OnTimeActivityAttributes.self) { context in
            LockScreenLiveActivityView(
                state: context.state,
                planId: context.attributes.planId,
                phase: .resolve(context.state, isStale: context.isStale)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            // True black, not a translucent plate: the spectrum only looks
            // lit when there is nothing behind it.
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let state = context.state
            let phase = RunPhase.resolve(state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: phase == .finished ? "checkmark.circle.fill" : state.glyph)
                            .font(.title3)
                            .foregroundStyle(phase == .finished ? OnTimeSpectrum.done
                                             : (phase == .over ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.isWaiting ? "Until start" : state.blockName)
                                .font(.headline)
                                .lineLimit(1)
                            Text(state.isWaiting ? "Before step 1" : "Step \(state.blockIndex + 1) of \(state.totalBlocks)")
                                .font(.caption2)
                                .foregroundStyle(OnTimeSpectrum.secondaryText)
                            (Text(state.normalizedTargetLabel) + Text(state.targetLeaveBy, style: .time))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(OnTimeSpectrum.primaryText)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        CountdownNumber(state: state, phase: phase, size: 34)
                        Text(caption(state: state, phase: phase))
                            .font(.caption2.weight(phase == .over ? .semibold : .regular))
                            .foregroundStyle(phase == .over ? OnTimeSpectrum.late : OnTimeSpectrum.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        StepPips(state: state, phase: phase)
                        // No action button while waiting — there's no step
                        // running yet to complete. None once finished
                        // either: there is nothing left to complete, and
                        // offering the button would invite a tap that does
                        // nothing.
                        if !state.isWaiting && phase != .finished {
                            CompleteButton(state: state, planId: context.attributes.planId, phase: phase)
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: phase == .finished ? "checkmark.circle.fill" : state.glyph)
                        .foregroundStyle(phase == .finished ? OnTimeSpectrum.done
                                         : (phase == .over ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText))
                    if !state.isWaiting && phase != .finished {
                        Text("\(state.blockIndex + 1)/\(state.totalBlocks)")
                            .font(.caption2.bold())
                    }
                }
            } compactTrailing: {
                CountdownNumber(state: state, phase: phase, size: 15)
                    .frame(width: 58, alignment: .trailing)
            } minimal: {
                CountdownRing(state: state, phase: phase)
            }
        }
    }

    private func caption(state: OnTimeActivityAttributes.ContentState, phase: RunPhase) -> String {
        switch phase {
        case .finished: return "finished"
        case .over: return state.overCaption
        case .running: return state.isWaiting ? "until start" : "until due"
        }
    }
}

/// A shared button so the Lock Screen and the expanded Island cannot drift.
private struct CompleteButton: View {
    let state: OnTimeActivityAttributes.ContentState
    let planId: String
    let phase: RunPhase

    var body: some View {
        Button(intent: CompleteStepIntent(planId: planId)) {
            HStack {
                Spacer()
                Label(state.blockIndex + 1 >= state.totalBlocks ? "Finish" : "Next Step",
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                // A plain edge, not a gradient one. The step pips above are
                // this plate's rainbow; a second one on the button underneath
                // them just makes the plate louder without saying more.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(phase == .over ? OnTimeSpectrum.late
                                                 : Color.white.opacity(0.30),
                                  lineWidth: 1.5)
            }
            .foregroundStyle(OnTimeSpectrum.primaryText)
        }
        .buttonStyle(.plain)
    }
}

/// The Clock app's shape for the collapsed Dynamic Island: a ring that
/// empties as the step runs out, rather than a static glyph that says
/// nothing about how much time is left.
///
/// `ProgressView(timerInterval:)` is the only thing here the system animates
/// by itself: the app is usually suspended while this is on screen, so
/// anything hand-drawn would freeze at whatever fraction was last pushed. The
/// ring therefore depletes on its own, in white. It used to be tinted by a
/// green to red ramp pushed twenty times a step; how far the ring has
/// depleted already says how much is left, and the two colours this plate
/// spends are late and finished.
private struct CountdownRing: View {
    let state: OnTimeActivityAttributes.ContentState
    let phase: RunPhase

    private var tint: Color { OnTimeSpectrum.primaryText }

    var body: some View {
        switch phase {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(OnTimeSpectrum.done)
        case .over:
            Circle()
                .strokeBorder(OnTimeSpectrum.late, lineWidth: 3)
        case .running:
            if let interval = state.ringInterval {
                ProgressView(timerInterval: interval, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(tint)
            } else {
                Circle()
                    .strokeBorder(tint, lineWidth: 3)
            }
        }
    }
}

private struct LockScreenLiveActivityView: View {
    let state: OnTimeActivityAttributes.ContentState
    let planId: String
    let phase: RunPhase

    // The Lock Screen view pins a black background, and the system chooses
    // the rendering colour scheme independently of that — adaptive
    // `.primary`/`.secondary` could resolve to near-black on the forced dark
    // plate. Explicit whites match the committed background.
    private var accent: Color {
        switch phase {
        case .finished: return OnTimeSpectrum.done
        case .over: return OnTimeSpectrum.late
        case .running: return OnTimeSpectrum.primaryText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.planName.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                    .lineLimit(1)
                Spacer()
                Text(state.isWaiting ? "UNTIL START" : "STEP \(state.blockIndex + 1) OF \(state.totalBlocks)")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            }

            HStack(alignment: .center, spacing: 14) {
                ring

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.isWaiting ? "Until start" : state.blockName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(OnTimeSpectrum.primaryText)
                        .lineLimit(1)
                    (Text(state.normalizedTargetLabel) + Text(state.targetLeaveBy, style: .time))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OnTimeSpectrum.secondaryText)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 1) {
                    CountdownNumber(state: state, phase: phase, size: 40)
                    Text(phase == .over ? state.overCaption
                         : (phase == .finished ? "finished" : (state.isWaiting ? "until start" : "until due")))
                        .font(.caption2.weight(phase == .over ? .semibold : .regular))
                        .foregroundStyle(phase == .over ? OnTimeSpectrum.late : OnTimeSpectrum.secondaryText)
                        .lineLimit(1)
                }
            }

            StepPips(state: state, phase: phase)

            if !state.isWaiting && phase != .finished {
                CompleteButton(state: state, planId: planId, phase: phase)
            }
        }
    }

    /// The step's glyph inside a ring that empties on its own. Small enough
    /// that the countdown stays the biggest thing on the plate.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 4)
            if phase == .running, let interval = state.ringInterval {
                ProgressView(timerInterval: interval, countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(OnTimeSpectrum.primaryText)
            } else {
                Circle()
                    .stroke(accent, lineWidth: 4)
            }
            Image(systemName: phase == .finished ? "checkmark" : state.glyph)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: 48, height: 48)
    }
}
