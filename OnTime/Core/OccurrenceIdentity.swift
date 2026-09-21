import CryptoKit
import Foundation

/// The `Plan.uuid` a routine's occurrence will have, known before the plan
/// exists.
///
/// The Pi starts a routine's Live Activity by push at the arm moment, with
/// the app closed, and an activity's `planId` is fixed at the moment it is
/// started. The run that belongs to it is only minted later, the next time
/// the app gets to execute. If that run took a random uuid, the engine would
/// look for an activity under its own id, find none, and request a second
/// one beside the pushed one. Deriving the uuid from the routine and the day
/// means both sides arrive at the same id without talking to each other, and
/// `LiveActivityManager.current(for:)` adopts the pushed activity as the
/// run's own.
///
/// Keyed on the occurrence's **day**, not its exact deadline, so moving the
/// anchor time after the Pi already has the schedule keeps the id: the app
/// then updates the pushed activity to the new time instead of orphaning it.
///
/// `ScheduleService.armNow` does not use this. A run started by hand after a
/// cancelled one would otherwise share a uuid with the cancelled plan.
enum OccurrenceIdentity {
    static func planUUID(routine: UUID, deadline: Date, calendar: Calendar = .current) -> UUID {
        let day = calendar.dateComponents([.year, .month, .day], from: deadline)
        let key = "\(routine.uuidString)|\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        let digest = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }
}
