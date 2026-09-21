import ActivityKit
import Foundation

/// The token that lets a server start this app's Live Activity while the app
/// is not running.
///
/// Nothing on the phone can put a countdown in the Dynamic Island at an exact
/// clock time: `Activity.request` only works in the foreground, and iOS will
/// not wake the app at the arm moment. A push can. APNs accepts a "start"
/// event addressed to this token and the system raises the activity with the
/// app closed. The sender is the Pi (`tools/pi/ontime_push.py`).
///
/// First slice only: the token is written to a file in Documents, where
/// `devicectl device copy from` can read it. Uploading it to the Pi replaces
/// the file once a push has been seen to work.
@MainActor
enum PushTokens {
    static let fileName = "push-tokens.json"

    static func startObserving() {
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

    private static func record(pushToStart token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let payload: [String: String] = [
            "pushToStart": hex,
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
