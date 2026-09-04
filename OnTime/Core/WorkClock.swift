import Foundation
import SwiftData

/// Start, stop, and the one invariant the work clock has: at most one
/// session open at a time.
///
/// Static functions over a passed-in `ModelContext`, the same shape
/// `ScheduleService` and `DeleteCleanup` use, so nothing here holds state
/// that could disagree with the store. The store *is* the state: a running
/// session is a row with no `endedAt`, which is why nothing needs restoring
/// on launch.
@MainActor
enum WorkClock {

    /// The currently running session, if any, with the duplicate case
    /// repaired on the way past.
    ///
    /// Two open sessions can only come from a bug, but if one ever happens
    /// the screen must not pick between them arbitrarily. The newest stays
    /// running; the older ones are closed at their own start time, so the
    /// repair shows up as a visible zero length row to fix by hand and
    /// cannot invent hours that were never worked. Closing them at "now"
    /// instead would silently add a day of paid time to a timesheet.
    @discardableResult
    static func openSession(in context: ModelContext) -> WorkSession? {
        let descriptor = FetchDescriptor<WorkSession>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let open = (try? context.fetch(descriptor)) ?? []
        guard let newest = open.first else { return nil }
        for stale in open.dropFirst() {
            stale.endedAt = stale.startedAt
            stale.note = stale.note.isEmpty ? "Closed automatically (was left open)" : stale.note
        }
        if open.count > 1 { save(context) }
        return newest
    }

    /// Starts the clock, or returns the session already running.
    ///
    /// The insert is saved immediately rather than left to autosave. That
    /// is the entire crash story: the interesting failure is the phone
    /// dying an hour into a shift, and an unsaved row would take the hour
    /// with it.
    @discardableResult
    static func start(at date: Date = Date(), in context: ModelContext) -> WorkSession {
        if let running = openSession(in: context) { return running }
        let session = WorkSession(startedAt: date)
        context.insert(session)
        save(context)
        return session
    }

    /// Stops the running session. A no-op when nothing is running.
    ///
    /// An end time before the start (only reachable by stopping a session
    /// whose start was hand edited into the future) is pulled up to the
    /// start rather than stored as negative work.
    @discardableResult
    static func stop(at date: Date = Date(), in context: ModelContext) -> WorkSession? {
        guard let running = openSession(in: context) else { return nil }
        running.endedAt = max(running.startedAt, date)
        save(context)
        return running
    }

    /// A `WorkSession` has no referrers, so this is a plain delete. See the
    /// type's own comment for why it does not go through `DeleteCleanup`.
    static func delete(_ session: WorkSession, in context: ModelContext) {
        context.delete(session)
        save(context)
    }

    private static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            print("WorkClock save failed: \(error)")
        }
    }
}
