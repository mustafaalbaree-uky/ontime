import Foundation

/// Compiled into both the app and the widget extension: the constants both
/// targets must agree on. These used to live as duplicated string literals
/// at every call site, where a typo in any one of them silently severed the
/// Complete Step button from the step advance with no compile error.
public enum OnTimeShared {
    /// Routing key for a "Complete Step" tap, whether it came from the Live
    /// Activity button (via `CompleteStepIntent`, which runs in the app
    /// process) or a notification's "Next Step" action. Posted on
    /// `NotificationCenter.default`; observed by `RunEngineStore`.
    public static let advanceStepNotification = Notification.Name("OnTimeAdvanceStepFromIntent")

    /// UserDefaults key holding the last step advance that may have arrived
    /// while no observer was alive. A `LiveActivityIntent` can launch the
    /// app in the background, where `RootView` never appears and so the
    /// observer never registers; the intent persists the tap here and the
    /// next real launch consumes it (`RunEngineStore.consumePendingAdvance`).
    public static let pendingAdvanceKey = "OnTimePendingAdvance"

    /// A persisted pending advance older than this is ignored at launch;
    /// completing a step from a tap made hours ago would be wrong more
    /// often than right.
    public static let pendingAdvanceMaxAge: TimeInterval = 6 * 60 * 60

    /// Routing key for "show me this run", posted when a notification is
    /// tapped. `userInfo` carries `planId` (a plan that already has a run) or
    /// `routineId` (an armed routine whose run may not exist until
    /// `ScheduleService.catchUp` has run on this foreground). `RootView`
    /// observes it, switches to the Now tab, and pages to the matching run.
    ///
    /// Before this existed, the arm alert's body said "Tap to open the
    /// countdown" and nothing in the app handled a plain notification tap at
    /// all: the tap just launched the app onto whatever tab it was last on.
    /// A notification that promises something and then does nothing is worse
    /// than one that promises nothing, and it was the loudest notification
    /// the app sends.
    public static let openRunNotification = Notification.Name("OnTimeOpenRunFromNotification")
}
