import ActivityKit
import Foundation
import SwiftData

/// The push tokens the Pi needs: the one that lets it start this app's Live
/// Activity while the app is not running, and each running activity's own
/// token, which lets it move that activity to the next step.
///
/// Nothing on the phone can put a countdown in the Dynamic Island at an exact
/// clock time: `Activity.request` only works in the foreground, and iOS will
/// not wake the app at the arm moment. A push can. APNs accepts a "start"
/// event addressed to this token and the system raises the activity with the
/// app closed. The sender is the Pi (`tools/pi/ontime_push.py`).
///
/// `PiSchedule` uploads the tokens with the schedule. The push to start
/// token is also written to a file in Documents, where
/// `devicectl device copy from` can read it, because a push sent by hand
/// with `tools/pi/ontime_push.py` is the quickest way to tell a Pi problem
/// from a phone problem.
@MainActor
enum PushTokens {
    static let fileName = "push-tokens.json"

    private static var modelContext: ModelContext?
    private static var trackedActivityIds: Set<String> = []

    static func startObserving(modelContext: ModelContext) {
        self.modelContext = modelContext
        observeActivities()
        guard #available(iOS 17.2, *) else { return }
        // The sequence only emits on a change, which on most launches is
        // never, so the value the system already holds is read first.
        if let token = Activity<OnTimeActivityAttributes>.pushToStartToken {
            record(pushToStart: token)
        }
        Task {
            for await token in Activity<OnTimeActivityAttributes>.pushToStartTokenUpdates {
                record(pushToStart: token)
            }
        }
    }

    // MARK: - Each activity's own token

    /// Changing an activity that is already up (the next step, the end of
    /// the run) is addressed to that activity's own token, not to the push
    /// to start token. Every activity is followed from here, whoever started
    /// it: `LiveActivityManager.start` in the foreground, or the Pi by push.
    private static func observeActivities() {
        for activity in Activity<OnTimeActivityAttributes>.activities {
            track(activity)
        }
        Task {
            for await activity in Activity<OnTimeActivityAttributes>.activityUpdates {
                track(activity)
            }
        }
    }

    private static func track(_ activity: Activity<OnTimeActivityAttributes>) {
        guard trackedActivityIds.insert(activity.id).inserted else { return }
        let planId = activity.attributes.planId
        if let token = activity.pushToken {
            PiSchedule.setActivityToken(planId: planId, hex: hex(token))
        }
        Task {
            for await token in activity.pushTokenUpdates {
                PiSchedule.setActivityToken(planId: planId, hex: hex(token))
            }
        }

        // An activity the Pi just started has no run behind it yet, and this
        // may be a background launch with no view hierarchy to run the usual
        // foreground catch up. Arming here, in the few seconds the push buys,
        // mints the run, and the engine's first sync hands the Pi the step
        // changes for the rest of the routine. For an activity the app
        // started itself this is the same idempotent pass as any foreground.
        if let modelContext {
            ScheduleService.catchUp(in: modelContext)
            try? modelContext.save()
        }
    }

    private static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The push to start token

    private static let defaultsKey = "pushToStartTokenHex"

    /// The last token the system handed over, kept across launches because
    /// `PiSchedule` needs it on launches where the sequence never emits.
    static var pushToStartHex: String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }

    private static func record(pushToStart token: Data) {
        let value = hex(token)
        if value != pushToStartHex {
            UserDefaults.standard.set(value, forKey: defaultsKey)
            PiSchedule.tokenChanged()
        }
        let payload: [String: String] = [
            "pushToStart": value,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        do {
            try data.write(to: documents.appendingPathComponent(fileName), options: .atomic)
        } catch {
            print("PushTokens: could not write \(fileName): \(error)")
        }
    }
}
