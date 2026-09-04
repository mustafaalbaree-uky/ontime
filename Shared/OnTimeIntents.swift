import AppIntents
import Foundation

public struct CompleteStepIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Complete Step"
    public static var description = IntentDescription("Marks current step complete and advances to next step.")
    public static var openAppWhenRun: Bool = false

    /// Which run this button belongs to — without this, more than one Live
    /// Activity up at once has no way to say which run's "Complete Step"
    /// was tapped, and the app-side listener (which no longer assumes a
    /// single `RunView` is even on screen) has nothing to route on.
    @Parameter(title: "Plan ID")
    public var planId: String

    public init() {
        self.planId = ""
    }

    public init(planId: String) {
        self.planId = planId
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        // Persist the tap before posting it. A LiveActivityIntent can launch
        // the app in the background, where the in-process observer
        // (`RunEngineStore`) may not exist yet — the post then lands on
        // nobody and the tap would be silently lost while this still
        // reported success. The observer clears the record when it handles
        // the live post; otherwise the next real launch consumes it.
        UserDefaults.standard.set(
            ["planId": planId, "at": Date().timeIntervalSince1970],
            forKey: OnTimeShared.pendingAdvanceKey
        )
        NotificationCenter.default.post(
            name: OnTimeShared.advanceStepNotification,
            object: nil,
            userInfo: ["planId": planId]
        )
        return .result()
    }
}
