import SwiftUI
import SwiftData

/// One running sequence, as a full page of the Now screen.
///
/// This is the answer to "I start a run, press Close, and it's gone." It
/// used to be: a manually started run appeared only inside a full-screen
/// cover, and dismissing that cover left the run alive with no trace of it
/// on the front screen — you had to know to go to the Active tab and read a
/// one-line list row to find the thing you were in the middle of doing.
/// Every open run is now a page of Now, and the run you are actually on is
/// the first thing the app shows when you open it.
///
/// The full `RunView` still exists behind the Steps button and is still
/// where a sequence is edited mid-run. This page is for the ninety percent
/// case: how long have I got, what am I doing, and done.
struct LiveRunPage: View {
    let run: Run
    /// Opens the full run screen (step list, editing, walk card).
    var onOpenFull: (Run) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var engine: RunEngine?
    @State private var confirmingCancel = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let engine {
                    header(engine)
                    hero(engine)
                    if let message = engine.solutionErrorMessage {
                        problem(message)
                    }
                    actions(engine)
                    upNext(engine)
                    stepStrip(engine)
                } else {
                    ProgressView()
                        .tint(OnTimeSpectrum.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .onAppear { engine = RunEngineStore.shared.engine(for: run) }
        // An `.alert`, not a `confirmationDialog`. This page lives inside a
        // paged `TabView`, and an action sheet presented from a page of one
        // routinely swallows its first tap while the pager settles — which is
        // exactly the "I pressed Stop and nothing happened, it took two goes"
        // report. An alert presents on the first tap. The confirmation step
        // itself stays: ending a run you are in the middle of is not
        // recoverable by pressing the button again.
        .alert("Stop this run?", isPresented: $confirmingCancel) {
            Button("Stop Run", role: .destructive) {
                RunEngineStore.shared.cancel(run)
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("The countdown and its Live Activity end.")
        }
    }

    // MARK: - Derived

    /// The moment this page is counting down to, and what it means.
    private func target(_ engine: RunEngine) -> Date? {
        if engine.isWaitingToStart { return engine.naturalStart }
        return engine.currentBlock.flatMap(engine.leaveByDate(for:))
    }

    private func remaining(_ engine: RunEngine) -> TimeInterval? {
        target(engine).map { $0.timeIntervalSince(engine.now) }
    }

    private var isLate: Bool {
        guard let engine, let remaining = remaining(engine) else { return false }
        return remaining < 0
    }

    // MARK: - Pieces

    /// Title in the middle, Stop in the corner.
    ///
    /// Stop used to sit at the very bottom, under the ring, the buttons and
    /// the step strip, which meant getting out of a run you had just started
    /// by mistake began with scrolling to find the way out. Ending the thing
    /// on screen belongs at the top of the thing on screen, in the corner
    /// where every other screen on the phone puts it.
    private func header(_ engine: RunEngine) -> some View {
        ZStack {
            VStack(spacing: 6) {
                // As typed. It used to be uppercased, bold and tracked.
                Text(engine.plan?.name ?? "Run")
                    .font(InkType.title)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                    .lineLimit(1)
                // Only when it adds something. A hand-started run is named
                // "By 12:50 AM", so the old unconditional subtitle rendered
                // "BY 12:50 AM" directly above "finishing by 12:50 AM" —
                // two lines of chrome saying one thing.
                if let deadline = engine.plan?.deadline,
                   engine.plan?.name.contains(TimeFormatting.clockString(deadline)) != true {
                    Text("finishing by \(TimeFormatting.clockString(deadline))")
                        .font(InkType.labelSmall)
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Spacer()
                Button {
                    confirmingCancel = true
                } label: {
                    // One of the few round controls left: a close button is
                    // a circle everywhere else on the phone.
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(OnTimeSpectrum.secondaryText)
                        .padding(9)
                        .background(Circle().fill(OnTimeSpectrum.surfaceRaised))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop this run")
            }
        }
        .padding(.top, 4)
    }

    /// The hero: the number, a flat bar under it, and what it is counting to.
    ///
    /// This used to be `SpectrumRing` — a rotating rainbow circle with the
    /// countdown in the middle. The ring was the loudest thing in the app and
    /// the least informative: the digits inside it already said everything it
    /// said. A run is the one screen you read while doing something else, so
    /// it is the one screen that has to be quiet. Colour on it now means
    /// exactly two things, late and done, and nothing else on it is coloured
    /// at all.
    private func hero(_ engine: RunEngine) -> some View {
        let target = target(engine)
        let span = target.map { $0.timeIntervalSince(engine.activitySegmentStart) } ?? 0
        let fraction = span > 0
            ? OnTimeActivityLogic.spanFraction(now: engine.now,
                                               segmentStart: engine.activitySegmentStart,
                                               target: target ?? engine.now)
            : 1
        let left = remaining(engine)
        let late = (left ?? 0) < 0
        let block = engine.currentBlock

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: engine.isWaitingToStart
                      ? "hourglass"
                      : (block?.template?.symbol ?? block?.kind.defaultSymbol ?? "timer"))
                    .font(InkType.label)
                    // Plain, like every other symbol on this screen. It used
                    // to take its hue from the step's index, which made the
                    // first step of a two step sequence render its car icon
                    // in pure red — the colour this app reserves for late.
                    .foregroundStyle(late ? OnTimeSpectrum.late : OnTimeSpectrum.secondaryText)

                Text(engine.isWaitingToStart
                     ? "Until start"
                     : (block.map { engine.targetLabel(for: $0) } ?? "Until next"))
                    .font(InkType.label)
                    .foregroundStyle(late ? OnTimeSpectrum.late : OnTimeSpectrum.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let t = target {
                    Text(TimeFormatting.clockString(t))
                        .font(InkType.label.monospacedDigit())
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                }
            }

            if let left {
                // Late reads as "+7:14" in red, never as a number that
                // silently turned around and started climbing. That is the
                // same fix the Live Activity got, and the two say the same
                // thing at the same moment.
                Text((late ? "+" : "") + TimeFormatting.compactCountdownString(abs(left)))
                    .onTimeNumeral(InkType.heroSize)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(late ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("…")
                    .font(OnTimeSpectrum.numeral(InkType.heroSize))
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TimeBar(fraction: fraction,
                    tint: late ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText)

            if let block {
                Text(block.name)
                    .font(InkType.rowTitle)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                    .lineLimit(1)
            }

            if let minutes = engine.latenessMinutes, minutes > 0 {
                Text("running \(minutes) min past \(TimeFormatting.clockString(engine.plan?.deadline ?? Date()))")
                    .font(InkType.labelSmall)
                    .foregroundStyle(OnTimeSpectrum.late)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectrumCard()
    }

    private func problem(_ message: String) -> some View {
        Text(message)
            .font(InkType.rowMeta)
            .foregroundStyle(OnTimeSpectrum.waiting)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .spectrumCard()
    }

    private func actions(_ engine: RunEngine) -> some View {
        VStack(spacing: 10) {
            if engine.isWaitingToStart {
                Button {
                    engine.beginFirstStepNow()
                } label: {
                    Label("Start Step 1 Now", systemImage: "play.fill")
                }
                .buttonStyle(SpectrumButtonStyle())
            } else {
                Button {
                    engine.advanceStep()
                } label: {
                    Label(engine.run.currentIndex + 1 >= engine.blocks.count ? "Finish" : "Next Step",
                          systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(SpectrumButtonStyle())
            }

            // Stop moved to the header's corner, so this row is just the way
            // through to the full step list.
            Button {
                onOpenFull(run)
            } label: {
                Label("Steps", systemImage: "list.bullet")
            }
            .buttonStyle(SpectrumButtonStyle(prominent: false))
        }
    }

    @ViewBuilder
    private func upNext(_ engine: RunEngine) -> some View {
        let nextIndex = engine.run.currentIndex + 1
        if engine.blocks.indices.contains(nextIndex) {
            let next = engine.blocks[nextIndex]
            HStack(spacing: 10) {
                Image(systemName: next.template?.symbol ?? next.kind.defaultSymbol)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
                Text("Then \(next.name)")
                    .font(InkType.bodyText)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                Spacer()
                if let t = engine.leaveByDate(for: next) {
                    Text(TimeFormatting.clockString(t))
                        .font(InkType.bodyText.monospacedDigit())
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                }
            }
            .padding(14)
            .spectrumCard()
        }
    }

    /// The whole sequence as one row of bars, in white. It used to take each
    /// segment's colour from `OnTimeSpectrum.step`, which is a hue by index
    /// — so "step 1 of 2" drew the step you were on in the exact red this
    /// app uses for running late, on a screen where nothing was wrong.
    /// Position in the sequence is what this bar is for, and position is
    /// carried by which segment is lit. Every segment is the same 3 pt: the
    /// current one used to stand taller as well.
    @ViewBuilder
    private func stepStrip(_ engine: RunEngine) -> some View {
        let total = max(engine.blocks.count, 1)
        // Nothing for a single step, on the same reasoning as the pager's
        // dots: a progress bar with one segment is a full-width bar that is
        // always full, which says nothing and looks like a stray UI element.
        // "Step 1 of 1" is not information either.
        if total > 1 {
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(engine.blocks.enumerated()), id: \.element.uuid) { index, _ in
                    let passed = index < engine.run.currentIndex
                    let current = index == engine.run.currentIndex
                    RoundedRectangle(cornerRadius: InkMetric.pipHeight / 2)
                        .fill(current ? Color.white.opacity(0.95)
                              : (passed ? Color.white.opacity(0.30) : Color.white.opacity(0.12)))
                        .frame(height: InkMetric.pipHeight)
                }
            }
            .animation(.easeInOut, value: engine.run.currentIndex)

            Text("Step \(min(engine.run.currentIndex + 1, total)) of \(total)")
                .font(InkType.labelSmall)
                .foregroundStyle(OnTimeSpectrum.tertiaryText)
            }
        }
    }
}
