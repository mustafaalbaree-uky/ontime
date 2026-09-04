import SwiftUI
import SwiftData

/// Every currently open `Run`: the equivalent of the Live Activities on the
/// Lock Screen, but inside the app, and independent of whether a Live
/// Activity actually started (they can be off in Settings). Tapping a row
/// goes back into that run's countdown, the same `RunView` it always was;
/// the point of this tab is that closing that screen no longer stops the run,
/// so there had to be a way back to it.
struct CountdownsView: View {
    @Query(filter: #Predicate<Run> { $0.finishedAt == nil }, sort: \Run.startedAt, order: .reverse)
    private var openRuns: [Run]

    @State private var selectedRun: Run?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "ACTIVE")

            ScrollView {
                VStack(alignment: .leading, spacing: InkMetric.cardToCard) {
                    if openRuns.isEmpty {
                        InkEmpty("Nothing running.")
                    } else {
                        ForEach(openRuns) { run in
                            Button {
                                selectedRun = run
                            } label: {
                                CountdownRow(run: run)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.bottom, InkMetric.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .spectrumBackground()
        .fullScreenCover(item: $selectedRun) { run in
            RunView(run: run)
        }
    }
}

private struct CountdownRow: View {
    let run: Run
    @State private var engine: RunEngine?

    var body: some View {
        StepRowCard(symbol: symbol, name: name, meta: [detail]) {
            countdown
        }
        .onAppear {
            engine = RunEngineStore.shared.engine(for: run)
        }
    }

    private var symbol: String {
        guard let engine else { return "timer" }
        if engine.isWaitingToStart { return "hourglass" }
        return engine.currentBlock?.template?.symbol ?? engine.currentBlock?.kind.defaultSymbol ?? "timer"
    }

    private var name: String {
        engine?.plan?.name ?? "Plan"
    }

    private var detail: String {
        guard let engine else { return "Starting" }
        if engine.isWaitingToStart { return "Until start" }
        guard let block = engine.currentBlock else { return "Running" }
        return "Step \(run.currentIndex + 1) of \(engine.blocks.count) · \(block.name)"
    }

    private var target: Date? {
        guard let engine else { return nil }
        return engine.isWaitingToStart
            ? engine.naturalStart
            : engine.currentBlock.flatMap(engine.leaveByDate(for:))
    }

    @ViewBuilder
    private var countdown: some View {
        if let engine, let target {
            let left = target.timeIntervalSince(engine.now)
            let late = left < 0
            StepRowValue(text: (late ? "+" : "") + TimeFormatting.compactCountdownString(abs(left)),
                         color: late ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText)
        } else {
            StepRowValue(text: "…", color: OnTimeSpectrum.tertiaryText)
        }
    }
}
