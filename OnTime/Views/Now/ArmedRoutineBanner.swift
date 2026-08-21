import SwiftUI
import SwiftData

/// The strip at the top of `NowView` when a scheduled routine has armed
/// itself. Tapping it opens that run's countdown.
///
/// Deliberately does *not* take over the Now screen: the scratch sequence
/// and its own Final Time stay exactly as they were. An armed routine is
/// something that showed up on its own, so displacing whatever the user was
/// in the middle of would be the app grabbing the wheel.
struct ArmedRoutineBanner: View {
    /// Open runs spawned by a scheduled routine. A run started by hand from
    /// the Start button has no `routine` and belongs in the Active tab, not
    /// up here.
    @Query(filter: #Predicate<Run> { $0.finishedAt == nil }, sort: \Run.startedAt, order: .reverse)
    private var openRuns: [Run]

    let now: Date
    let onOpen: (Run) -> Void

    private var armedRuns: [Run] {
        openRuns.filter { $0.plan?.routine != nil }
    }

    var body: some View {
        if !armedRuns.isEmpty {
            VStack(spacing: 8) {
                ForEach(armedRuns) { run in
                    Button {
                        onOpen(run)
                    } label: {
                        BannerRow(run: run, now: now)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BannerRow: View {
    let run: Run
    let now: Date

    @State private var engine: RunEngine?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(run.plan?.name ?? "Routine")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(countdown)
                .font(.headline.monospacedDigit())
                .foregroundStyle(isLate ? .red : .primary)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { engine = RunEngineStore.shared.engine(for: run) }
    }

    private var target: Date? {
        guard let engine else { return nil }
        return engine.isWaitingToStart
            ? engine.naturalStart
            : engine.currentBlock.flatMap(engine.leaveByDate(for:))
    }

    private var isLate: Bool {
        guard let target else { return false }
        return now >= target
    }

    private var detail: String {
        guard let engine else { return "Starting…" }
        if engine.isWaitingToStart { return "Waiting to start" }
        guard let block = engine.currentBlock else { return "Running" }
        return "Step \(run.currentIndex + 1) of \(engine.blocks.count) — \(block.name)"
    }

    private var countdown: String {
        guard let target else { return "—" }
        let seconds = Int(abs(target.timeIntervalSince(now)))
        let minutes = seconds / 60
        let text = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return isLate ? "+\(text)" : text
    }
}
