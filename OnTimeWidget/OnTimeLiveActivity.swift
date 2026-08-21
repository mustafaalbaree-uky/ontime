import ActivityKit
import SwiftUI
import WidgetKit

/// What the activity is actually showing right now, which is not always
/// what the app last pushed. The app is suspended for most of a run, so a
/// step whose target has passed cannot be updated by anyone — the widget
/// works it out from the clock and from `context.isStale`, which
/// ActivityKit sets by re-rendering at the stale date the app asked for
/// (the step's target time; see `LiveActivityManager.staleDate`).
private enum RunPhase {
    /// Still counting down to the step's target.
    case running
    /// The last step's target passed and the step advances on its own, so
    /// the run is over — the app just hasn't been awake to say so.
    case finished
    /// The target passed on a step that waits for a tap. Time is counting
    /// up, and that is correct, but it needs to be labeled as over rather
    /// than left as a bare climbing number.
    case over

    static func resolve(_ state: OnTimeActivityAttributes.ContentState, isStale: Bool) -> RunPhase {
        let past = isStale || state.isOverrun || state.targetLeaveBy <= Date()
        guard past else { return .running }
        return state.endsRunAtTarget ? .finished : .over
    }
}

private extension OnTimeActivityAttributes.ContentState {
    /// The step's span, clamped so it is always ascending —
    /// `ProgressView(timerInterval:)` traps on a non-ascending range.
    var ringInterval: ClosedRange<Date>? {
        guard segmentStart < targetLeaveBy else { return nil }
        return segmentStart...targetLeaveBy
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
            .padding(.vertical, 12)
            .activityBackgroundTint(Color.black.opacity(0.75))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            let state = context.state
            let phase = RunPhase.resolve(state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: phase == .finished ? "checkmark.circle.fill" : (state.isWaiting ? "hourglass" : state.symbol))
                            .font(.title3)
                            .foregroundStyle(phase == .finished ? Color.green : (state.isWaiting || state.isFlex ? Color.orange : Color.accentColor))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.isWaiting ? "Wait Time" : state.blockName)
                                .font(.headline)
                                .lineLimit(1)
                            Text(state.isWaiting ? "Before step 1" : "Step \(state.blockIndex + 1) of \(state.totalBlocks)")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                            (Text(state.targetLabel) + Text(state.targetLeaveBy, style: .time))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if phase == .finished {
                            Text("Done")
                                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                                .foregroundStyle(Color.green)
                            Text("finished on the dot")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        } else {
                            Text(state.targetLeaveBy, style: .timer)
                                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                                .monospacedDigit()
                                .minimumScaleFactor(0.6)
                                .foregroundStyle(phase == .over ? Color.orange : Color.primary)
                            if phase == .over {
                                Text(state.latenessMinutes.map { $0 > 0 ? "over — ~\($0)m late" : "over — still on time" } ?? "over — waiting on you")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.orange)
                            } else {
                                Text(state.isWaiting ? "until start" : "until finish")
                                    .font(.caption2)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }

                // No action button while waiting — there's no step running
                // yet to complete; `RunView.beginFirstStepNow` is what ends
                // the wait, and that only happens from the app or the clock.
                // None once finished either: there is nothing left to
                // complete, and offering the button would invite a tap that
                // does nothing.
                DynamicIslandExpandedRegion(.bottom) {
                    if !state.isWaiting && phase != .finished {
                        Button(intent: CompleteStepIntent(planId: context.attributes.planId)) {
                            HStack {
                                Spacer()
                                Label(state.blockIndex + 1 >= state.totalBlocks ? "Finish Plan" : "Done — Complete Step",
                                      systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                            }
                        }
                        .tint(phase == .over ? Color.orange : Color.accentColor)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: phase == .finished ? "checkmark.circle.fill" : (state.isWaiting ? "hourglass" : state.symbol))
                        .foregroundStyle(phase == .finished ? Color.green : (state.isWaiting || state.isFlex ? Color.orange : Color.accentColor))
                    if !state.isWaiting && phase != .finished {
                        Text("\(state.blockIndex + 1)/\(state.totalBlocks)")
                            .font(.caption2.bold())
                    }
                }
            } compactTrailing: {
                if phase == .finished {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.green)
                } else {
                    Text(state.targetLeaveBy, style: .timer)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .frame(width: 52, alignment: .trailing)
                        .foregroundStyle(phase == .over ? Color.orange : Color.primary)
                }
            } minimal: {
                CountdownRing(state: state, phase: phase)
            }
        }
    }
}

/// The Clock app's shape for the collapsed Dynamic Island: a ring that
/// empties as the step runs out, rather than a static glyph that says
/// nothing about how much time is left.
///
/// `ProgressView(timerInterval:)` is the only thing here the system
/// animates by itself — the app is usually suspended while this is on
/// screen, so anything hand-drawn would freeze at whatever fraction was
/// last pushed. The ring therefore depletes on its own; only the tint
/// changes on a pushed update, which `RunEngine.rampBucket` does twenty
/// times across the step.
private struct CountdownRing: View {
    let state: OnTimeActivityAttributes.ContentState
    let phase: RunPhase

    /// Green at the top of the step through red at the deadline, by hue,
    /// so it reads as one continuous ramp rather than three named stops.
    private var tint: Color {
        let span = state.targetLeaveBy.timeIntervalSince(state.segmentStart)
        guard span > 0 else { return .red }
        let fraction = min(max(Date().timeIntervalSince(state.segmentStart) / span, 0), 1)
        return Color(hue: 0.33 * (1 - fraction), saturation: 0.9, brightness: 0.95)
    }

    var body: some View {
        switch phase {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .over:
            Circle()
                .strokeBorder(Color.orange, lineWidth: 3)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.planName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Text(state.isWaiting ? "WAIT TIME" : "STEP \(state.blockIndex + 1) OF \(state.totalBlocks)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary)
            }

            HStack(spacing: 12) {
                Image(systemName: phase == .finished ? "checkmark.circle.fill" : (state.isWaiting ? "hourglass" : state.symbol))
                    .font(.title2)
                    .foregroundStyle(phase == .finished ? Color.green : (state.isWaiting || state.isFlex ? Color.orange : Color.accentColor))

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.blockName)
                        .font(.headline)
                    (Text(state.targetLabel) + Text(state.targetLeaveBy, style: .time))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if phase == .finished {
                        Text("Done")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.green)
                        Text("finished on the dot")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    } else {
                        Text(state.targetLeaveBy, style: .timer)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .foregroundStyle(phase == .over ? Color.orange : Color.primary)
                        if phase == .over {
                            Text(state.latenessMinutes.map { $0 > 0 ? "over — ~\($0)m late" : "over — still on time" } ?? "over — waiting on you")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.orange)
                        } else {
                            Text(state.isWaiting ? "until start" : "until finish")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }

            if !state.isWaiting && phase != .finished {
                Button(intent: CompleteStepIntent(planId: planId)) {
                    HStack {
                        Spacer()
                        Label(state.blockIndex + 1 >= state.totalBlocks ? "Finish Plan" : (phase == .over ? "Done — Complete Step" : "Complete Step"),
                              systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
                .tint(phase == .over ? Color.orange : Color.accentColor)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
