import Foundation
import Testing
@testable import OnTime

/// `upcoming(after:limit:)` reads from a week of occurrences per routine
/// (see `WidgetBridge.upcoming`), so a naive date sort shows the same
/// routine several times when there are only one or two routines. These
/// tests pin down the dedupe: one row per routine, the soonest occurrence,
/// soonest routine first.
struct OnTimeWidgetSnapshotTests {

    private func upcoming(uuid: UUID, deadline: Date, name: String = "Routine") -> OnTimeWidgetSnapshot.Upcoming {
        OnTimeWidgetSnapshot.Upcoming(
            id: "\(uuid.uuidString)-\(Int(deadline.timeIntervalSince1970))",
            name: name,
            deadline: deadline,
            mustStartAt: deadline.addingTimeInterval(-600),
            armAt: deadline.addingTimeInterval(-3600),
            stepCount: 1,
            symbol: "timer"
        )
    }

    @Test("One routine with three occurrences yields one row: the soonest")
    func oneRoutineDedupes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let routine = UUID()
        let occurrences = [
            upcoming(uuid: routine, deadline: now.addingTimeInterval(3600)),
            upcoming(uuid: routine, deadline: now.addingTimeInterval(3600 * 25)),
            upcoming(uuid: routine, deadline: now.addingTimeInterval(3600 * 49))
        ]
        let snapshot = OnTimeWidgetSnapshot(upcoming: occurrences)

        let rows = snapshot.upcoming(after: now)

        #expect(rows.count == 1)
        #expect(rows.first?.deadline == now.addingTimeInterval(3600))
    }

    @Test("Two routines yield two rows, soonest first")
    func twoRoutinesOneRowEach() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let soonRoutine = UUID()
        let laterRoutine = UUID()
        let occurrences = [
            // Later routine's own soonest occurrence is still after the
            // soon routine's soonest, even though it is listed first here.
            upcoming(uuid: laterRoutine, deadline: now.addingTimeInterval(3600 * 5), name: "Later"),
            upcoming(uuid: laterRoutine, deadline: now.addingTimeInterval(3600 * 29), name: "Later"),
            upcoming(uuid: soonRoutine, deadline: now.addingTimeInterval(3600), name: "Soon"),
            upcoming(uuid: soonRoutine, deadline: now.addingTimeInterval(3600 * 25), name: "Soon")
        ]
        let snapshot = OnTimeWidgetSnapshot(upcoming: occurrences)

        let rows = snapshot.upcoming(after: now)

        #expect(rows.count == 2)
        #expect(rows[0].name == "Soon")
        #expect(rows[0].deadline == now.addingTimeInterval(3600))
        #expect(rows[1].name == "Later")
        #expect(rows[1].deadline == now.addingTimeInterval(3600 * 5))
    }

    @Test("changePoints still fires on every occurrence, not just the soonest")
    func changePointsUnaffectedByDedupe() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let routine = UUID()
        let first = now.addingTimeInterval(3600)
        let second = now.addingTimeInterval(3600 * 25)
        let occurrences = [
            upcoming(uuid: routine, deadline: first),
            upcoming(uuid: routine, deadline: second)
        ]
        let snapshot = OnTimeWidgetSnapshot(upcoming: occurrences)

        let points = snapshot.changePoints(after: now)

        // Both deadlines (plus each occurrence's armAt and mustStartAt)
        // still show up, so the widget still re-renders when the first
        // occurrence passes and the second becomes the soonest row.
        #expect(points.contains(first))
        #expect(points.contains(second))
    }

    // MARK: - A live run moves on by the clock

    private func step(_ index: Int, until: Date) -> OnTimeShownStep {
        OnTimeShownStep(name: "Step \(index + 1)", symbol: "circle", index: index,
                        target: until, targetLabel: "Finish by", until: until)
    }

    private func run(now: Date, later: [OnTimeShownStep]) -> OnTimeWidgetSnapshot.LiveRun {
        OnTimeWidgetSnapshot.LiveRun(
            id: UUID().uuidString, name: "Morning", deadline: now.addingTimeInterval(1800),
            stepName: "Step 1", symbol: "circle", stepIndex: 0, totalSteps: 3,
            segmentStart: now.addingTimeInterval(-300), target: now.addingTimeInterval(600),
            targetLabel: "Finish by", isWaiting: false, until: now.addingTimeInterval(600), later: later
        )
    }

    /// The app is suspended for the whole routine, so the snapshot on disk is
    /// the one written at step 1. The widget used to go red at the first
    /// boundary and stay red to the end.
    @Test("A snapshot written at step 1 shows step 2 once step 1's time has passed")
    func liveRunMovesOn() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let second = step(1, until: now.addingTimeInterval(1200))
        let third = step(2, until: now.addingTimeInterval(1800))
        let snapshot = OnTimeWidgetSnapshot(runs: [run(now: now, later: [second, third])])

        #expect(snapshot.liveRuns(at: now).first?.stepIndex == 0)

        let shown = snapshot.liveRuns(at: now.addingTimeInterval(601)).first
        #expect(shown?.stepIndex == 1)
        #expect(shown?.stepName == "Step 2")
        #expect(shown?.target == second.target)
        #expect(shown?.segmentStart == now.addingTimeInterval(600))
    }

    @Test("A run whose last step's time has passed is gone, not shown as over")
    func liveRunDropsOff() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = OnTimeWidgetSnapshot(runs: [run(now: now, later: [step(1, until: now.addingTimeInterval(1200))])])

        #expect(snapshot.liveRuns(at: now.addingTimeInterval(1199)).count == 1)
        #expect(snapshot.liveRuns(at: now.addingTimeInterval(1200)).isEmpty)
    }

    @Test("The widget re-renders at every step boundary of a live run")
    func changePointsIncludeEveryStep() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let second = step(1, until: now.addingTimeInterval(1200))
        let snapshot = OnTimeWidgetSnapshot(runs: [run(now: now, later: [second])])

        let points = snapshot.changePoints(after: now)

        #expect(points.contains(now.addingTimeInterval(600)))
        #expect(points.contains(second.until))
    }

    @Test("A snapshot file from before later existed still decodes")
    func oldSnapshotDecodes() throws {
        let old = """
        {"generatedAt":780000000,"upcoming":[],"runs":[{"id":"a","name":"Morning","deadline":780003600,
         "stepName":"Shower","symbol":"shower","stepIndex":1,"totalSteps":4,"segmentStart":780000000,
         "target":780000600,"targetLabel":"Finish by","isWaiting":false}]}
        """
        let decoded = try JSONDecoder().decode(OnTimeWidgetSnapshot.self, from: Data(old.utf8))
        #expect(decoded.runs.first?.until == decoded.runs.first?.target)
        #expect(decoded.runs.first?.later.isEmpty == true)
    }
}
