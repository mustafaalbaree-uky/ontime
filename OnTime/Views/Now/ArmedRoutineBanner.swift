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
            RadarDot(isLate: isLate)

            VStack(alignment: .leading, spacing: 1) {
                Text(run.plan?.name ?? "Routine")
                    .font(InkType.rowTitle)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                Text(detail)
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
            }

            Spacer()

            Text(countdown)
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(isLate ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText)

            Image(systemName: "chevron.right")
                .font(InkType.label)
                .foregroundStyle(OnTimeSpectrum.tertiaryText)
        }
        .padding(InkMetric.rowPadding)
        .spectrumCard()
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
        guard let engine else { return "Starting" }
        // Same words as the Active tab's row and the run page's label.
        if engine.isWaitingToStart { return "Until start" }
        guard let block = engine.currentBlock else { return "Running" }
        return "Step \(run.currentIndex + 1) of \(engine.blocks.count) · \(block.name)"
    }

    private var countdown: String {
        guard let target else { return "…" }
        let seconds = Int(abs(target.timeIntervalSince(now)))
        let minutes = seconds / 60
        let text = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return isLate ? "+\(text)" : text
    }
}

/// The live dot on an armed routine's banner. A plain 8pt circle read as a
/// static status light; the point of the banner is that something is
/// *running right now*, so the dot radiates the way a radar sweep does —
/// two rings staggered half a cycle apart, expanding and fading out from
/// under the solid centre.
///
/// The rings are drawn at full size and scaled down rather than grown from
/// zero, so the animation never asks SwiftUI to re-lay-out the row: the
/// frame is a fixed 8pt and the rings overflow it without affecting the
/// `HStack`'s spacing.
private struct RadarDot: View {
    let isLate: Bool

    @State private var pulsing = false

    private var tint: Color { isLate ? OnTimeSpectrum.late : OnTimeSpectrum.done }

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { ring in
                Circle()
                    .fill(tint)
                    .frame(width: 24, height: 24)
                    .scaleEffect(pulsing ? 1.0 : 0.33)
                    .opacity(pulsing ? 0.0 : 0.45)
                    .animation(
                        .easeOut(duration: 1.8)
                            .repeatForever(autoreverses: false)
                            .delay(Double(ring) * 0.9),
                        value: pulsing
                    )
            }

            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        }
        .frame(width: 8, height: 8)
        .onAppear { pulsing = true }
    }
}
