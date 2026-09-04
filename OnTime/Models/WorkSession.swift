import Foundation
import SwiftData

/// One stretch of paid work.
///
/// `endedAt == nil` is the *only* representation of "this session is
/// running." There is no separate `isRunning` flag that could disagree with
/// the timestamps, and there is no in-memory engine holding the state: the
/// row is inserted and saved the moment Start is tapped, so a crash, a
/// force quit, or a phone that dies mid shift leaves a still open session on
/// disk, and the next launch finds it with an ordinary query instead of
/// reconstructing anything.
///
/// Nothing points at a `WorkSession` and it points at nothing, so unlike
/// `TaskTemplate`, `Place` and `ScheduledRoutine` it does not need
/// `DeleteCleanup`: a bare `modelContext.delete` leaves no dangling
/// reference behind. If this ever grows a relationship, that stops being
/// true.
@Model
final class WorkSession {
    /// Stable identity, per the same rule the rest of the schema follows:
    /// a `persistentModelID` is provisional until the first save and moves
    /// under you afterwards, so anything outliving autosave keys on `uuid`.
    var uuid: UUID = UUID()
    var startedAt: Date = Date()
    /// Nil while the clock is running. Set once, on Stop or by hand.
    var endedAt: Date?
    var note: String = ""
    /// True for a session typed in after the fact rather than clocked live.
    /// Purely informational: the week math treats both identically, but a
    /// row you invented from memory is worth being able to spot later.
    var wasEnteredManually: Bool = false

    init(startedAt: Date = Date(), endedAt: Date? = nil,
         note: String = "", wasEnteredManually: Bool = false) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.note = note
        self.wasEnteredManually = wasEnteredManually
    }

    var isRunning: Bool { endedAt == nil }

    /// Seconds on the clock, counting up to `now` while still running.
    /// Clamped at zero so a hand edited end time that lands before the
    /// start reads as empty rather than as negative work.
    func seconds(now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// The value form the week math works in, so `WorkHours` never has to
    /// import SwiftData.
    func interval(now: Date = Date()) -> WorkInterval {
        WorkInterval(start: startedAt, end: max(startedAt, endedAt ?? now))
    }
}
