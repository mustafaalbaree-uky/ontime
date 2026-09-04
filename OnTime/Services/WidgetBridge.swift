import Foundation
import SwiftData
import WidgetKit

/// Keeps the Home Screen widget's snapshot current.
///
/// The widget reads a file, never the store (see `OnTimeWidgetSnapshot` for
/// why), so something in the app has to write that file whenever the answer
/// changes. This is that something: one place that assembles the whole
/// picture — every live run plus every routine's next occurrence — and
/// writes it if it differs from what is already on disk.
///
/// **Deduplicated on content, not on call count.** `RunEngine` pushes state
/// about twenty times per step (the Live Activity's ramp buckets), and the
/// snapshot is unchanged for nineteen of them. Comparing the encoded bytes
/// means a widget reload happens on a step advance, a run starting or
/// ending, and an edit to a routine, and not once per second.
@MainActor
@Observable
final class WidgetBridge {
    static let shared = WidgetBridge()

    private var modelContext: ModelContext?
    private var lastWritten: Data?
    private var refreshPending = false

    private init() {}

    /// Called once at launch alongside `RunEngineStore.configure`.
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Coalescing entry point. Several things can move in one runloop pass
    /// (a step advances, which re-solves, which re-pushes) and they should
    /// produce one snapshot between them.
    func setNeedsRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor in
            self.refreshPending = false
            self.refresh()
        }
    }

    func refresh(now: Date = Date()) {
        guard let context = modelContext else { return }
        // An App Group that never provisioned leaves no container. Failing
        // quietly here is right: the widget shows its empty state and the
        // rest of the app is unaffected.
        guard OnTimeWidgetStore.containerURL != nil else { return }

        let snapshot = OnTimeWidgetSnapshot(
            generatedAt: now,
            runs: liveRuns(now: now),
            upcoming: upcoming(in: context, now: now)
        )

        guard let data = OnTimeWidgetStore.encode(snapshot) else { return }
        // `generatedAt` moves on every call, so it is excluded from the
        // comparison by comparing the rest of the payload rather than the
        // whole thing.
        if let lastWritten, sameContent(lastWritten, data) { return }
        guard let written = OnTimeWidgetStore.write(snapshot) else { return }
        lastWritten = written
        WidgetCenter.shared.reloadTimelines(ofKind: OnTimeWidgetStore.kind)
    }

    /// Equal apart from `generatedAt`.
    private func sameContent(_ a: Data, _ b: Data) -> Bool {
        guard let x = try? JSONDecoder().decode(OnTimeWidgetSnapshot.self, from: a),
              let y = try? JSONDecoder().decode(OnTimeWidgetSnapshot.self, from: b) else { return false }
        return x.runs == y.runs && x.upcoming == y.upcoming
    }

    // MARK: - Assembling

    private func liveRuns(now: Date) -> [OnTimeWidgetSnapshot.LiveRun] {
        RunEngineStore.shared.openEngines.compactMap { engine in
            guard let plan = engine.plan else { return nil }
            let block = engine.currentBlock
            let target = engine.isWaitingToStart
                ? engine.naturalStart
                : block.flatMap(engine.leaveByDate(for:))
            return OnTimeWidgetSnapshot.LiveRun(
                id: plan.uuid.uuidString,
                name: plan.name,
                deadline: plan.deadline,
                stepName: block?.name ?? "",
                symbol: block?.template?.symbol ?? block?.kind.defaultSymbol ?? "timer",
                stepIndex: engine.run.currentIndex,
                totalSteps: engine.blocks.count,
                segmentStart: engine.activitySegmentStart,
                target: target,
                targetLabel: block.map { engine.targetLabel(for: $0) } ?? "start",
                isWaiting: engine.isWaitingToStart
            )
        }
        .sorted { ($0.target ?? $0.deadline) < ($1.target ?? $1.deadline) }
    }

    /// A week of occurrences, not just the next one. The widget is asked to
    /// render at moments the app has no say over, so it needs enough rows in
    /// hand to still be right after several days without a launch.
    private func upcoming(in context: ModelContext,
                          now: Date,
                          calendar: Calendar = .current) -> [OnTimeWidgetSnapshot.Upcoming] {
        guard let routines = try? context.fetch(FetchDescriptor<ScheduledRoutine>()) else { return [] }

        // Routines whose run is already live are represented by that run;
        // listing the occurrence as well would show the same thing twice.
        let livePlanRoutines: Set<UUID> = Set(
            RunEngineStore.shared.openEngines.compactMap { $0.plan?.routine?.uuid }
        )

        var items: [OnTimeWidgetSnapshot.Upcoming] = []
        for routine in routines {
            guard routine.isEnabled, !routine.orderedBlocks.isEmpty else { continue }
            guard !livePlanRoutines.contains(routine.uuid) else { continue }

            // Walk forward a week, asking for the occurrence after each one
            // found, so a daily routine contributes seven rows rather than
            // only tomorrow's.
            var cursor = now
            for _ in 0..<7 {
                guard let occurrence = ScheduleService.nextOccurrence(
                    for: routine, now: cursor, calendar: calendar
                ) else { break }
                items.append(OnTimeWidgetSnapshot.Upcoming(
                    id: "\(routine.uuid.uuidString)-\(Int(occurrence.deadline.timeIntervalSince1970))",
                    name: routine.name.isEmpty ? "Untitled" : routine.name,
                    deadline: occurrence.deadline,
                    mustStartAt: occurrence.mustStartAt,
                    armAt: occurrence.armAt,
                    stepCount: routine.orderedBlocks.count,
                    symbol: routine.orderedBlocks.first.map {
                        $0.template?.symbol ?? $0.kind.defaultSymbol
                    } ?? "repeat"
                ))
                cursor = occurrence.deadline.addingTimeInterval(60)
            }
        }
        return items.sorted { $0.deadline < $1.deadline }
    }
}
