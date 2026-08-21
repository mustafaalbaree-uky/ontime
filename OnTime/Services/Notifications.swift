import Foundation
import UserNotifications
import UIKit

@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()

    private let center = UNUserNotificationCenter.current()
    private var settings: AppSettings { .shared }
    /// Tracks which pending-notification identifiers belong to which plan,
    /// so one run's notifications can be replaced/cancelled without an
    /// async round-trip through `getPendingNotificationRequests` (whose
    /// completion could otherwise land *after* a subsequent
    /// `scheduleRunNotifications` call for the same plan and delete the
    /// notifications it just added — a real race with two runs ticking
    /// concurrently). Removing by a synchronously-known identifier set has
    /// no such ordering hazard.
    private var scheduledIdentifiers: [String: Set<String>] = [:]

    enum Category: String {
        case runStep = "ONTIME_RUN_STEP"
        case routineArm = "ONTIME_ROUTINE_ARM"
    }

    enum Action: String {
        case nextStep = "NEXT_STEP"
        case startRoutine = "START_ROUTINE"
    }

    /// Identifier prefix for a scheduled routine's arm alarm, so the whole
    /// set can be replaced wholesale on every reschedule without touching a
    /// running plan's step notifications.
    static let armAlarmPrefix = "ontime-routine-arm-"
    private var armAlarmIdentifiers: Set<String> = []

    override init() {
        super.init()
        center.delegate = self
    }

    func registerCategories() {
        let nextAction = UNNotificationAction(
            identifier: Action.nextStep.rawValue,
            title: "Next Step",
            options: [.foreground]
        )

        let stepCategory = UNNotificationCategory(
            identifier: Category.runStep.rawValue,
            actions: [nextAction],
            intentIdentifiers: [],
            options: []
        )

        // `.foreground` so the tap brings the app up and the run is
        // materialized with a Live Activity attached. The countdown itself
        // doesn't depend on this being tapped promptly — `ScheduleService`
        // derives everything from the clock, so arming late still lands on
        // the correct remaining time rather than restarting it.
        let startAction = UNNotificationAction(
            identifier: Action.startRoutine.rawValue,
            title: "Start",
            options: [.foreground]
        )

        let armCategory = UNNotificationCategory(
            identifier: Category.routineArm.rawValue,
            actions: [startAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([stepCategory, armCategory])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func cancelAllRunNotifications() {
        center.removeAllPendingNotificationRequests()
        scheduledIdentifiers.removeAll()
    }

    /// Cancels only one plan's pending step notifications, without touching
    /// any other concurrently running plan's. See `scheduledIdentifiers`
    /// doc for why this doesn't just query the notification center.
    func cancelRunNotifications(planId: String) {
        guard let ids = scheduledIdentifiers.removeValue(forKey: planId), !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: Array(ids))
    }

    private static let quickLeaveByIdentifier = "ontime-quick-leaveby"

    /// A single one-off "time to go" alert for `NowView`'s quick countdown —
    /// deliberately independent of `cancelAllRunNotifications`/
    /// `scheduleRunNotifications` (which are `Plan`-scoped) so starting a
    /// quick timer never clobbers a real `Run`'s pending notifications, and
    /// vice versa.
    func scheduleQuickCountdownNotification(leaveBy: Date) {
        cancelQuickCountdownNotification()
        guard leaveBy > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time to go"
        content.body = "You need to start now to make it on time."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: leaveBy)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: Self.quickLeaveByIdentifier, content: content, trigger: trigger)
        center.add(req)
    }

    func cancelQuickCountdownNotification() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.quickLeaveByIdentifier])
    }

    /// A one-off local alarm at an exact clock time, armed by tapping a
    /// "must start by" / "must start at" time directly rather than setting
    /// up anything separately. `id` lets more than one screen own its own
    /// alarm (e.g. `NowView`'s quick countdown vs. `RunView`'s wait phase)
    /// without one re-arming clobbering the other's.
    func armAlarm(id: String, fireAt: Date, title: String, body: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard fireAt > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(req)
    }

    // MARK: - Scheduled routine arm alarms

    /// The one guaranteed layer of the arming model: iOS will deliver this
    /// at the exact moment regardless of whether the app is running, which
    /// nothing else available without a push server will do. Foregrounding
    /// and background refresh are the opportunistic layers.
    func scheduleArmAlarm(routineId: String, name: String, fireAt: Date, mustStartAt: Date) {
        guard fireAt > Date() else { return }
        let identifier = Self.armAlarmPrefix + routineId

        let content = UNMutableNotificationContent()
        content.title = name
        let minutes = max(0, Int(mustStartAt.timeIntervalSince(fireAt) / 60.0))
        content.body = minutes > 0
            ? "Starts in \(minutes) min — tap to open the countdown."
            : "Time to start."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Category.routineArm.rawValue

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        armAlarmIdentifiers.insert(identifier)
    }

    /// Replaced wholesale on every reschedule — an arm time moves whenever a
    /// step's duration changes, so patching individual alarms would leave
    /// stale ones behind.
    func cancelAllArmAlarms() {
        if !armAlarmIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(armAlarmIdentifiers))
            armAlarmIdentifiers.removeAll()
        }
        // The set above is in-memory, so after a relaunch it's empty and
        // knows nothing about alarms scheduled in a previous session. Sweep
        // by prefix as well to catch those — notably a routine deleted while
        // the app wasn't running, whose alarm would otherwise fire for
        // something that no longer exists.
        //
        // The sweep is async, and callers reschedule immediately after
        // calling this, so its completion can easily land *after* the new
        // alarms are in. Filtering against `armAlarmIdentifiers` as it
        // stands at completion time — not as it stood at request time — is
        // what keeps it from deleting the very alarms that just replaced
        // the stale ones.
        center.getPendingNotificationRequests { requests in
            let candidates = requests.map(\.identifier).filter { $0.hasPrefix(Self.armAlarmPrefix) }
            guard !candidates.isEmpty else { return }
            Task { @MainActor in
                let stale = candidates.filter { !self.armAlarmIdentifiers.contains($0) }
                guard !stale.isEmpty else { return }
                self.center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }
    }

    func scheduleRunNotifications(for plan: Plan, solution: Solution) {
        let planId = "\(plan.id)"
        if let old = scheduledIdentifiers[planId], !old.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(old))
        }
        var newIdentifiers: Set<String> = []
        let now = Date()
        let leadWarningMinutes = settings.defaultLeadWarningMinutes
        let blocks = plan.orderedBlocks

        for (index, block) in blocks.enumerated() {
            guard let sched = solution.blocks.first(where: { $0.index == block.order }) else { continue }
            let targetDate: Date
            switch sched.constraint {
            case .hardLeaveBy(let d): targetDate = d
            case .flexAbsorbs: targetDate = sched.scheduledEnd
            }

            // 1. Lead warning (e.g. 5 min before)
            let leadDate = targetDate.addingTimeInterval(-Double(leadWarningMinutes * 60))
            if leadDate > now {
                let content = UNMutableNotificationContent()
                content.title = "\(block.name) • \(leadWarningMinutes)m left"
                content.body = Self.leadBody(
                    block: block,
                    isLast: index == blocks.count - 1,
                    nextName: index + 1 < blocks.count ? blocks[index + 1].name : nil,
                    targetDate: targetDate
                )
                content.sound = .default
                content.categoryIdentifier = Category.runStep.rawValue
                content.interruptionLevel = .active
                content.userInfo = ["planId": planId]

                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: leadDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let identifier = "ontime-lead-\(planId)-\(block.id)-\(index)"
                let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                center.add(req)
                newIdentifiers.insert(identifier)
            }

            // 2. Final deadline / leave by
            if targetDate > now {
                let content = UNMutableNotificationContent()
                content.title = Self.dueTitle(block: block, isLast: index == blocks.count - 1)
                content.body = Self.dueBody(
                    block: block,
                    isLast: index == blocks.count - 1,
                    nextName: index + 1 < blocks.count ? blocks[index + 1].name : nil,
                    deadline: plan.deadline
                )
                content.sound = .default
                content.categoryIdentifier = Category.runStep.rawValue
                content.interruptionLevel = .active
                content.userInfo = ["planId": planId]

                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: targetDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let identifier = "ontime-due-\(planId)-\(block.id)-\(index)"
                let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                center.add(req)
                newIdentifiers.insert(identifier)
            }
        }
        scheduledIdentifiers[planId] = newIdentifiers
    }

    /// A drive ends by arriving, everything else by being finished, and
    /// the last step ends the whole plan. "Time to leave / finish: Drive"
    /// with "target time reached for step 1 of 2" said none of that: it
    /// read as an instruction to leave while already most of the way
    /// there, and counted steps nobody thinks in.
    private static func dueTitle(block: Block, isLast: Bool) -> String {
        if block.kind == .drive { return "Should be arriving: \(block.name)" }
        return isLast ? "Deadline: \(block.name)" : "Time's up: \(block.name)"
    }

    private static func dueBody(block: Block, isLast: Bool, nextName: String?, deadline: Date) -> String {
        if isLast { return "That's the \(formatTimeStatic(deadline)) deadline. Nothing left after this." }
        if let nextName { return "Next up: \(nextName)." }
        return "On to the next step."
    }

    private static func leadBody(block: Block, isLast: Bool, nextName: String?, targetDate: Date) -> String {
        let verb = block.kind == .drive ? "Arrive" : "Finish"
        let t = formatTimeStatic(targetDate)
        if isLast { return "\(verb) by \(t) and you're done." }
        if let nextName { return "\(verb) by \(t), then \(nextName)." }
        return "\(verb) by \(t) to stay on schedule."
    }

    private static func formatTimeStatic(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            completionHandler([.banner, .sound, .list])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if response.actionIdentifier == Action.nextStep.rawValue,
               let planId = response.notification.request.content.userInfo["planId"] as? String {
                NotificationCenter.default.post(
                    name: NSNotification.Name("OnTimeAdvanceStepFromIntent"),
                    object: nil,
                    userInfo: ["planId": planId]
                )
            }
            completionHandler()
        }
    }
}
