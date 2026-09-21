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

    /// The index of the step the plate was showing when it was tapped. The
    /// plate moves on by the clock while the app is suspended, so it can be
    /// ahead of the run the app holds, or behind it. Naming the step lets the
    /// engine complete what he was looking at, and ignore a tap on a step
    /// that is already done (`RunEngine.completeShownStep`).
    @Parameter(title: "Step")
    public var step: Int

    public init() {
        self.planId = ""
        self.step = 0
    }

    public init(planId: String, step: Int) {
        self.planId = planId
        self.step = step
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
            ["planId": planId, "step": step, "at": Date().timeIntervalSince1970],
            forKey: OnTimeShared.pendingAdvanceKey
        )
        NotificationCenter.default.post(
            name: OnTimeShared.advanceStepNotification,
            object: nil,
            userInfo: ["planId": planId, "step": step]
        )
        return .result()
    }
}
