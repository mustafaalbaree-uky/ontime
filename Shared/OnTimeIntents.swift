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
        NotificationCenter.default.post(
            name: NSNotification.Name("OnTimeAdvanceStepFromIntent"),
            object: nil,
            userInfo: ["planId": planId]
        )
        return .result()
    }
}
