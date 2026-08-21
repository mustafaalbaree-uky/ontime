import SwiftUI
import SwiftData

/// Lists every currently-open `Run` — the equivalent of the Live Activities
/// on the Lock Screen, but inside the app, and independent of whether a
/// Live Activity actually started (Live Activities can be off in Settings).
/// Tapping a row goes back into that run's live countdown, same screen
/// `RunView` always was; the point of this tab is that closing that screen
/// no longer stops the run, so there needed to be a way back to it besides
/// digging through Plans.
struct CountdownsView: View {
    @Query(filter: #Predicate<Run> { $0.finishedAt == nil }, sort: \Run.startedAt, order: .reverse)
    private var openRuns: [Run]

    @State private var selectedRun: Run?

    var body: some View {
        NavigationStack {
            Group {
                if openRuns.isEmpty {
                    ContentUnavailableView(
                        "No Countdowns Running",
                        systemImage: "timer",
                        description: Text("Start a plan from Now or Plans and it'll show up here — even after you close its countdown screen.")
                    )
                } else {
                    List(openRuns) { run in
                        CountdownRow(run: run)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedRun = run }
                    }
                }
            }
            .navigationTitle("Countdowns")
        }
        .fullScreenCover(item: $selectedRun) { run in
            RunView(run: run)
        }
    }
}

private struct CountdownRow: View {
    let run: Run
    @State private var engine: RunEngine?

    var body: some View {
        HStack(spacing: 12) {
            if let engine {
                Image(systemName: engine.currentBlock?.template?.symbol ?? engine.currentBlock?.kind.defaultSymbol ?? "timer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.plan?.name ?? "Plan")
                        .font(.body.weight(.semibold))
                    Text(engine.isWaitingToStart
                         ? "Waiting to start"
                         : (engine.currentBlock.map { "Step \(run.currentIndex + 1) of \(engine.blocks.count) — \($0.name)" } ?? "Running"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let target = engine.isWaitingToStart ? engine.naturalStart : engine.currentBlock.flatMap(engine.leaveByDate(for:)) {
                    Text(target, style: .relative)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(engine.isCurrentBlockOverrun ? .orange : .primary)
                }
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            engine = RunEngineStore.shared.engine(for: run)
        }
    }
}
