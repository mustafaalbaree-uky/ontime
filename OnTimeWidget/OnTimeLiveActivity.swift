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
//
// The type is look A, the same as the app: SF Pro at regular weight, the
// countdown thin, sentence case, no tracking, pips all one height, and a
// white Next Step button with no outline. This plate and the Island were the
// two screens the owner disliked most in the old look, which was SF Rounded
// bold, tracked capitals and an outlined button.

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

    var body: some View {
        switch phase {
        case .finished:
            Text("Done")
                .onTimeNumeral(size)
                .foregroundStyle(OnTimeSpectrum.done)
        case .over:
            HStack(spacing: 0) {
                Text("+")
                    .onTimeNumeral(size)
                Text(timerInterval: state.lateInterval, countsDown: false)
                    .onTimeNumeral(size)
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
            .onTimeNumeral(size)
            .multilineTextAlignment(.trailing)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(OnTimeSpectrum.primaryText)
        }
    }
}

/// The run's progress as a row of pips, one per step, all 3 pt tall: the
/// current one lit, the ones behind it dimmer, the ones ahead dimmest. The
/// same three whites as the Home Screen widget and the run page, so the phone
/// and the Lock Screen say the same thing in the same way.
private struct StepPips: View {
    let state: OnTimeActivityAttributes.ContentState
    let phase: RunPhase

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(state.totalBlocks, 1), id: \.self) { i in
                let passed = phase == .finished || i < state.blockIndex
                let current = phase != .finished && i == state.blockIndex
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(current ? Color.white.opacity(0.95)
                          : (passed ? Color.white.opacity(0.30) : Color.white.opacity(0.12)))
                    .frame(height: 3)
            }
        }
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
            // True black, not a translucent plate: the same ground the app
            // draws on, so the three whites read the same in both places.
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let state = context.state
            let phase = RunPhase.resolve(state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: phase == .finished ? "checkmark.circle.fill" : state.glyph)
                            .font(.system(size: 18))
                            .foregroundStyle(phase == .finished ? OnTimeSpectrum.done
                                             : (phase == .over ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.isWaiting ? "Until start" : state.blockName)
                                .font(.system(size: 17))
                                .lineLimit(1)
                            Text(state.isWaiting ? "Before step 1" : "Step \(state.blockIndex + 1) of \(state.totalBlocks)")
                                .font(.system(size: 12))
                                .foregroundStyle(OnTimeSpectrum.secondaryText)
                            (Text(state.normalizedTargetLabel) + Text(state.targetLeaveBy, style: .time))
                                .font(.system(size: 12))
                                .foregroundStyle(OnTimeSpectrum.secondaryText)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        CountdownNumber(state: state, phase: phase, size: 36)
                        Text(caption(state: state, phase: phase))
                            .font(.system(size: 11.5))
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
                            .font(.system(size: 12.5))
                            .foregroundStyle(OnTimeSpectrum.secondaryText)
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
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(.vertical, 9)
            // The app's primary button: white plate, black text, 10 pt corner,
            // no outline. It stays white once the step is over. The outline it
            // used to have turned red then; the red countdown above carries
            // that state on its own.
            .background(OnTimeSpectrum.primaryText)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(OnTimeSpectrum.ink)
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
                // The plan's name as typed, not uppercased.
                Text(state.planName)
                    .font(.system(size: 12))
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                    .lineLimit(1)
                Spacer()
                Text(state.isWaiting ? "Until start" : "Step \(state.blockIndex + 1) of \(state.totalBlocks)")
                    .font(.system(size: 12))
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            }

            HStack(alignment: .center, spacing: 14) {
                ring

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.isWaiting ? "Until start" : state.blockName)
                        .font(.system(size: 18))
                        .foregroundStyle(OnTimeSpectrum.primaryText)
                        .lineLimit(1)
                    (Text(state.normalizedTargetLabel) + Text(state.targetLeaveBy, style: .time))
                        .font(.system(size: 12.5))
                        .foregroundStyle(OnTimeSpectrum.secondaryText)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 1) {
                    CountdownNumber(state: state, phase: phase, size: 44)
                    Text(phase == .over ? state.overCaption
                         : (phase == .finished ? "finished" : (state.isWaiting ? "until start" : "until due")))
                        .font(.system(size: 11.5))
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
                .stroke(Color.white.opacity(0.12), lineWidth: 3)
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
                    .stroke(accent, lineWidth: 3)
            }
            Image(systemName: phase == .finished ? "checkmark" : state.glyph)
                .font(.system(size: 16))
                .foregroundStyle(accent)
        }
        .frame(width: 44, height: 44)
    }
}
