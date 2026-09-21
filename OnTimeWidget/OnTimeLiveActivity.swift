import ActivityKit
import SwiftUI
import WidgetKit

/// Which step is on show and the ring's span guard live in `Shared/` (see
/// `OnTimeShown` and `ContentState.shown(isStale:now:)`): pure functions both
/// targets compile, so the app's test target can pin them down. Every view
/// here is handed the state already resolved, never `context.state` itself.

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
// tinted white. The one colour on this plate is green for a finished run. A
// step whose time has passed is not drawn at all: the plate is on the next
// step by then (`ContentState.shown`), and a run with no step left is ended.
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

    /// `targetLabel` arrives with a trailing space by convention; enforcing
    /// the separator here means a future label without one renders as
    /// "Finish by 7:15" instead of "Finish by7:15".
    var normalizedTargetLabel: String {
        targetLabel.trimmingCharacters(in: .whitespaces) + " "
    }

    var glyph: String {
        isWaiting ? "hourglass" : symbol
    }

    var caption: String {
        isFinished ? "finished" : (isWaiting ? "until start" : "until due")
    }
}

/// The countdown. It counts down and stops at 0:00, because a
/// `Text(timerInterval:)` built from a *range* clamps at both of that range's
/// ends on its own.
///
/// The clamping is the whole reason this uses the range form rather than
/// `Text(_:style: .timer)`, which free-runs past its date and starts climbing
/// unannounced. Do **not** reach for `pauseTime` to get the clamp: passing it
/// renders the timer as *paused* rather than as running-until-paused, so the
/// number froze on the Lock Screen and never counted at all. The range alone
/// is the fix.
private struct CountdownNumber: View {
    let state: OnTimeActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        if state.isFinished {
            Text("Done")
                .onTimeNumeral(size)
                .foregroundStyle(OnTimeSpectrum.done)
        } else {
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

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(state.totalBlocks, 1), id: \.self) { i in
                let passed = state.isFinished || i < state.blockIndex
                let current = !state.isFinished && i == state.blockIndex
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
                state: context.state.shown(isStale: context.isStale),
                planId: context.attributes.planId
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            // True black, not a translucent plate: the same ground the app
            // draws on, so the three whites read the same in both places.
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let state = context.state.shown(isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: state.isFinished ? "checkmark.circle.fill" : state.glyph)
                            .font(.system(size: 18))
                            .foregroundStyle(state.isFinished ? OnTimeSpectrum.done : OnTimeSpectrum.primaryText)
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
                        CountdownNumber(state: state, size: 36)
                        Text(state.caption)
                            .font(.system(size: 11.5))
                            .foregroundStyle(OnTimeSpectrum.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        StepPips(state: state)
                        // No action button while waiting — there's no step
                        // running yet to complete. None once finished
                        // either: there is nothing left to complete, and
                        // offering the button would invite a tap that does
                        // nothing.
                        if !state.isWaiting && !state.isFinished {
                            CompleteButton(state: state, planId: context.attributes.planId)
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: state.isFinished ? "checkmark.circle.fill" : state.glyph)
                        .foregroundStyle(state.isFinished ? OnTimeSpectrum.done : OnTimeSpectrum.primaryText)
                    if !state.isWaiting && !state.isFinished {
                        Text("\(state.blockIndex + 1)/\(state.totalBlocks)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(OnTimeSpectrum.secondaryText)
                    }
                }
            } compactTrailing: {
                CountdownNumber(state: state, size: 15)
                    .frame(width: 58, alignment: .trailing)
            } minimal: {
                CountdownRing(state: state)
            }
        }
    }
}

/// A shared button so the Lock Screen and the expanded Island cannot drift.
private struct CompleteButton: View {
    let state: OnTimeActivityAttributes.ContentState
    let planId: String

    var body: some View {
        // The step on the plate, which the clock may have moved past the one
        // the app last sent. The tap completes what he is looking at.
        Button(intent: CompleteStepIntent(planId: planId, step: state.blockIndex)) {
            HStack {
                Spacer()
                Label(state.blockIndex + 1 >= state.totalBlocks ? "Finish" : "Next Step",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(.vertical, 9)
            // The app's primary button: white plate, black text, 10 pt corner,
            // no outline.
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
/// depleted already says how much is left, and the one colour this plate
/// spends is green for finished.
private struct CountdownRing: View {
    let state: OnTimeActivityAttributes.ContentState

    private var tint: Color { OnTimeSpectrum.primaryText }

    var body: some View {
        if state.isFinished {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(OnTimeSpectrum.done)
        } else if let interval = state.ringInterval {
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

private struct LockScreenLiveActivityView: View {
    let state: OnTimeActivityAttributes.ContentState
    let planId: String

    // The Lock Screen view pins a black background, and the system chooses
    // the rendering colour scheme independently of that — adaptive
    // `.primary`/`.secondary` could resolve to near-black on the forced dark
    // plate. Explicit whites match the committed background.
    private var accent: Color {
        state.isFinished ? OnTimeSpectrum.done : OnTimeSpectrum.primaryText
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
                    CountdownNumber(state: state, size: 44)
                    Text(state.caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnTimeSpectrum.secondaryText)
                        .lineLimit(1)
                }
            }

            StepPips(state: state)

            if !state.isWaiting && !state.isFinished {
                CompleteButton(state: state, planId: planId)
            }
        }
    }

    /// The step's glyph inside a ring that empties on its own. Small enough
    /// that the countdown stays the biggest thing on the plate.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 3)
            if !state.isFinished, let interval = state.ringInterval {
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
            Image(systemName: state.isFinished ? "checkmark" : state.glyph)
                .font(.system(size: 16))
                .foregroundStyle(accent)
        }
        .frame(width: 44, height: 44)
    }
}
