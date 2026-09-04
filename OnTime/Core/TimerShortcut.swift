import UIKit

/// The "OnTime Timer" Shortcut handoff: opens the Shortcut with the number
/// of seconds until a target, and the Shortcut creates a real timer in the
/// Clock app. This lived as two character-for-character copies in `NowView`
/// and `RunView`.
@MainActor
enum TimerShortcut {
    /// Returns false when the target is already past, with a warning haptic
    /// so the tap is visibly not a dead one; the old versions silently
    /// no-op'd on a button that looked live.
    @discardableResult
    static func arm(for target: Date) -> Bool {
        guard target > Date() else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return false
        }

        let seconds = max(1, Int(target.timeIntervalSince(Date()).rounded()))
        let encoded = "\(seconds)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(seconds)"
        guard let url = URL(string: "shortcuts://run-shortcut?name=OnTime%20Timer&input=text&text=\(encoded)") else {
            return false
        }
        UIApplication.shared.open(url)
        return true
    }
}
