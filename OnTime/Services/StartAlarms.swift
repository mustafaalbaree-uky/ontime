import Foundation
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

/// A real alarm at the moment a routine has to start, set by the app itself.
///
/// A notification is the wrong instrument for "step 1 begins now" when step 1
/// is "Wake up": it is one sound, it obeys silent mode and Focus, and a
/// sleeping person does not hear it. AlarmKit (iOS 26) gives an app the Clock
/// app's own alarm: it rings until stopped, through silent mode and Focus,
/// with the system's full screen alert. Before it existed the only way to get
/// one was the "OnTime Timer" shortcut behind the builder's timer icon, which
/// starts a Clock timer and shows nothing in this app to say it did.
///
/// Same principle as the arm notifications and the Pi schedule: an alarm is an
/// **absolute clock time handed to the system in advance**, so it rings with
/// the app closed. `ScheduleService.refreshArmAlarms` hands over the coming
/// occurrences of every routine that asks for one.
///
/// An alarm's id is the occurrence's derived plan uuid
/// (`OccurrenceIdentity`), so the run that occurrence arms can find and cancel
/// its own alarm without any bookkeeping between the two.
@MainActor
enum StartAlarms {
    struct Wanted: Equatable {
        let id: UUID
        let fireAt: Date
        let title: String
    }

    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Asks once; afterwards reports what the user chose. False means alarms
    /// are off for OnTime in iOS Settings, or this iOS has no AlarmKit.
    static func authorize() async -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .denied: return false
        default:
            return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        }
    }

    static var isDenied: Bool {
        guard #available(iOS 26.0, *) else { return true }
        return AlarmManager.shared.authorizationState == .denied
    }

    // MARK: - Routine alarms

    private static let routineIdsKey = "startAlarmRoutineAlarmIds"
    /// Bumped by every `setRoutineAlarms`, so a pass that was overtaken
    /// while awaiting the system stops instead of finishing stale work.
    private static var generation = 0

    /// Replaces every routine alarm with `wanted`. One set by hand for a
    /// single run (`set(id:fireAt:title:)`) is left alone: only ids this
    /// function scheduled earlier are ever cancelled by it.
    static func setRoutineAlarms(_ wanted: [Wanted]) {
        guard #available(iOS 26.0, *) else { return }
        generation += 1
        let mine = generation
        let previous = Set(UserDefaults.standard.stringArray(forKey: routineIdsKey) ?? [])
        let future = wanted.filter { $0.fireAt > Date().addingTimeInterval(5) }
        UserDefaults.standard.set(future.map(\.id.uuidString), forKey: routineIdsKey)

        Task {
            let existing = (try? AlarmManager.shared.alarms) ?? []
            let keep = Set(future.map(\.id.uuidString))
            for id in previous where !keep.contains(id) {
                if let uuid = UUID(uuidString: id) { try? AlarmManager.shared.cancel(id: uuid) }
            }
            for alarm in future {
                guard mine == generation else { return }
                if let current = existing.first(where: { $0.id == alarm.id }) {
                    // Already set for this exact moment: leave it. Cancelling
                    // and setting again would be a window with no alarm.
                    if current.schedule == .fixed(alarm.fireAt) { continue }
                    try? AlarmManager.shared.cancel(id: alarm.id)
                }
                await schedule(alarm)
            }
        }
    }

    // MARK: - One alarm, set by hand for one run

    @discardableResult
    static func set(id: UUID, fireAt: Date, title: String) async -> Bool {
        guard #available(iOS 26.0, *), fireAt > Date(), await authorize() else { return false }
        try? AlarmManager.shared.cancel(id: id)
        return await schedule(Wanted(id: id, fireAt: fireAt, title: title))
    }

    static func cancel(id: UUID) {
        guard #available(iOS 26.0, *) else { return }
        try? AlarmManager.shared.cancel(id: id)
    }

    /// The moment an alarm with this id will ring, if one is set.
    static func fireDate(id: UUID) -> Date? {
        guard #available(iOS 26.0, *) else { return nil }
        guard let alarm = (try? AlarmManager.shared.alarms)?.first(where: { $0.id == id }),
              case .fixed(let date)? = alarm.schedule else { return nil }
        return date
    }

    // MARK: - AlarmKit

    @available(iOS 26.0, *)
    private struct NoMetadata: AlarmMetadata {}

    @available(iOS 26.0, *)
    @discardableResult
    private static func schedule(_ alarm: Wanted) async -> Bool {
        // iOS 26.1 made the stop button the system's own and dropped it from
        // the initializer; 26.0 still has to be handed one.
        let title = LocalizedStringResource(stringLiteral: alarm.title)
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title)
        } else {
            alert = AlarmPresentation.Alert(
                title: title,
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
            )
        }
        let attributes = AlarmAttributes<NoMetadata>(presentation: AlarmPresentation(alert: alert),
                                                     tintColor: .white)
        do {
            _ = try await AlarmManager.shared.schedule(
                id: alarm.id,
                configuration: .alarm(schedule: .fixed(alarm.fireAt), attributes: attributes)
            )
            return true
        } catch {
            print("StartAlarms: could not set \(alarm.title) for \(alarm.fireAt): \(error)")
            return false
        }
    }
}
