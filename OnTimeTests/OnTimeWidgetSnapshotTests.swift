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
}
