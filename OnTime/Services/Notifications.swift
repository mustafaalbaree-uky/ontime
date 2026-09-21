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

    /// The plan whose countdown is on screen right now, set by the Now
    /// screen's live run card. Its own notifications are suppressed entirely
    /// while it is visible: an alert telling you a step is due, banner and
    /// sound, on top of the full-screen ring already showing that same step
    /// running out, is the app interrupting you to say what you are looking
    /// at. Everything else still presents, because a *different* plan's step
    /// coming due is genuinely news.
    var visiblePlanId: String?

    /// Whether a notification's sound should be attached at all. Off makes
    /// every alert this app posts silent, banners included — the setting for
    /// wanting the information without the noise.
    private var soundIfEnabled: UNNotificationSound? {
        settings.notificationSoundEnabled ? .default : nil
    }

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

    /// Adds a request and at least records a refusal somewhere. Every
    /// `center.add` in this file used to discard its result, so a denied
    /// authorization or a full pending queue left the bookkeeping claiming
    /// alarms that never existed, with no trace anywhere.
    private func add(_ req: UNNotificationRequest) {
        center.add(req) { error in
            if let error {
                print("Notification add failed for \(req.identifier): \(error)")
            }
        }
    }

    /// Removes delivered notifications whose identifiers start with any of
    /// `prefixes`. Pending-only cancellation left every already-fired
    /// banner ("Starts in 20 min") stacked in Notification Center during
    /// and after the run it announced.
    private func removeDelivered(withPrefixes prefixes: [String]) {
        center.getDeliveredNotifications { notes in
            let ids = notes.map(\.request.identifier).filter { id in
                prefixes.contains { id.hasPrefix($0) }
            }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Cancels every *run step* notification this app has pending, and the
    /// delivered leftovers. Deliberately NOT `removeAllPendingNotificationRequests`:
    /// that wiped the routine arm chains and walk alarms too, and only a
    /// caller-ordering convention (refreshArmAlarms running right after)
    /// put the arm alarms back.
    func cancelAllRunNotifications() {
        let known = scheduledIdentifiers.values.flatMap { $0 }
        if !known.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(known))
        }
        scheduledIdentifiers.removeAll()
        // The in-memory map is empty after a relaunch; sweep the run step
        // prefixes to catch requests scheduled in a previous session.
        center.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter {
                $0.hasPrefix(Self.leadPrefix) || $0.hasPrefix(Self.duePrefix)
            }
            guard !stale.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
        }
        removeDelivered(withPrefixes: [Self.leadPrefix, Self.duePrefix])
    }

    /// Cancels only one plan's pending step notifications, without touching
    /// any other concurrently running plan's. See `scheduledIdentifiers`
    /// doc for why this doesn't just query the notification center.
    func cancelRunNotifications(planId: String) {
        removeDelivered(withPrefixes: ["\(Self.leadPrefix)\(planId)", "\(Self.duePrefix)\(planId)"])
        guard let ids = scheduledIdentifiers.removeValue(forKey: planId), !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: Array(ids))
    }

    /// Drops every pending step notification that does not belong to one of
    /// `planIds`, by sweeping the identifier prefixes rather than the
    /// in-memory map.
    ///
    /// `scheduledIdentifiers` is memory only, so after a force-quit it comes
    /// back empty and knows nothing about requests a previous session
    /// armed. `cancelAllRunNotifications` sweeps by prefix, but it only runs
    /// when there are *no* open runs at all — so a session with one run still
    /// going kept firing a dead run's alerts on schedule, and a plan whose
    /// step count had shrunk kept the higher-index requests forever. This is
    /// the same sweep, scoped to what is actually still running.
    func cancelRunNotifications(exceptPlanIds planIds: Set<String>) {
        let keepPrefixes = planIds.flatMap { ["\(Self.leadPrefix)\($0)-", "\(Self.duePrefix)\($0)-"] }
        func isStale(_ id: String) -> Bool {
            guard id.hasPrefix(Self.leadPrefix) || id.hasPrefix(Self.duePrefix) else { return false }
            return !keepPrefixes.contains { id.hasPrefix($0) }
        }
        center.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter(isStale)
            guard !stale.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
        }
        center.getDeliveredNotifications { notes in
            let stale = notes.map(\.request.identifier).filter(isStale)
            guard !stale.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    /// A one-off local alarm at an exact clock time. `id` lets more than
    /// one caller own its own alarm without one re-arming clobbering the
    /// other's. A fire time already in the past is a no-op that leaves any
    /// previously armed request standing — cancelling first and then
    /// refusing the past date is how the walk turnaround alert used to
    /// silently disarm itself; a caller that wants an immediate alert uses
    /// `deliverAlarmNow` instead.
    func armAlarm(id: String, fireAt: Date, title: String, body: String) {
        guard fireAt > Date() else { return }
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        add(UNNotificationRequest(identifier: id, content: alarmContent(title: title, body: body), trigger: trigger))
    }

    /// Delivers an alarm immediately, replacing any pending request with the
    /// same id — for the moment an alarm was armed for turning out to be
    /// already behind us.
    func deliverAlarmNow(id: String, title: String, body: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        add(UNNotificationRequest(identifier: id, content: alarmContent(title: title, body: body), trigger: nil))
    }

    private func alarmContent(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = soundIfEnabled
        // Walk alarms stay time-sensitive whatever else is turned down: the
        // turnaround is the one moment in this app where being told late and
        // being told nothing are the same outcome.
        content.interruptionLevel = .timeSensitive
        return content
    }

    /// Drops one or more `armAlarm` requests by id, pending and delivered
    /// both. Alarms armed this way are not tracked in
    /// `scheduledIdentifiers` (that map is `Plan`-scoped and these are
    /// not), so cancelling them is a plain removal rather than a lookup.
    func cancelAlarms(ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    // MARK: - Scheduled routine arm alarms

    /// Two alerts per arm window, and never more: a heads-up when the window
    /// opens, and one at the moment you actually have to start.
    ///
    /// This used to be a *chain* — one at the arm moment and another every
    /// ten minutes right up to the start, capped at seven. The reasoning was
    /// that iOS won't pin a banner on screen, so a lingering reminder had to
    /// be built out of repeats stacked under one `threadIdentifier`. What it
    /// actually produced was up to seven time-sensitive, sounding
    /// interruptions per occurrence, each one saying a near-identical
    /// sentence about a number the Lock Screen and the Live Activity were
    /// both already displaying, and each one breaking through Focus to do it.
    /// Repetition is not persistence. The two alerts kept here are the two
    /// that carry information the previous alert didn't: the window is open,
    /// and the window is closing.
    ///
    /// Only the second is `.timeSensitive`. The heads-up is `.active`, so a
    /// routine arming during Do Not Disturb no longer forces its way in an
    /// hour early.
    private static let armMinimumGap: TimeInterval = 5 * 60

    /// The one guaranteed layer of the arming model: iOS will deliver these
    /// at the exact moment regardless of whether the app is running, which
    /// nothing else available without a push server will do. Foregrounding
    /// and background refresh are the opportunistic layers.
    func scheduleArmAlarm(routineId: String, name: String, fireAt: Date, mustStartAt: Date) {
        let now = Date()
        guard fireAt > now else { return }

        let alerts = Self.armAlertTimes(from: fireAt, to: mustStartAt)
        for (index, alertAt) in alerts.enumerated() {
            guard alertAt > now else { continue }
            let identifier = "\(Self.armAlarmPrefix)\(routineId)-\(index)"
            let isFinal = index == alerts.count - 1

            let content = UNMutableNotificationContent()
            content.title = name
            content.body = Self.armBody(alertAt: alertAt, mustStartAt: mustStartAt)
            content.sound = soundIfEnabled
            // Only the go moment breaks through Focus. See `armMinimumGap`.
            content.interruptionLevel = isFinal ? .timeSensitive : .active
            content.categoryIdentifier = Category.routineArm.rawValue
            content.userInfo = ["routineId": routineId]
            // Stacks every alert of one arm window under the routine's name
            // instead of scattering them down the Lock Screen.
            content.threadIdentifier = Self.armAlarmPrefix + routineId
            // Closer to the start time is more worth surfacing, so the
            // Notification Summary picks the latest one.
            content.relevanceScore = min(1.0, 0.5 + Double(index) * 0.1)

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: alertAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            armAlarmIdentifiers.insert(identifier)
        }
    }

    /// The heads-up when the window opens, then the moment you have to go.
    ///
    /// A window shorter than `armMinimumGap` collapses to the single go
    /// alert: two banners a couple of minutes apart, saying "starts in 3
    /// min" and then "start now", is the repetition this was built to stop,
    /// and the second one is the one worth keeping. A zero-length window
    /// (a routine with no steps, so arm and start are the same instant)
    /// yields exactly one alert rather than two identical ones.
    static func armAlertTimes(from armAt: Date, to mustStartAt: Date) -> [Date] {
        guard mustStartAt > armAt else { return [armAt] }
        guard mustStartAt.timeIntervalSince(armAt) >= armMinimumGap else { return [mustStartAt] }
        return [armAt, mustStartAt]
    }

    static func armBody(alertAt: Date, mustStartAt: Date) -> String {
        let minutes = Int((mustStartAt.timeIntervalSince(alertAt) / 60.0).rounded())
        // "Tap to open the countdown" is a promise now kept: a plain tap on
        // this notification routes through `OnTimeShared.openRunNotification`
        // to the Now screen's page for this routine's run. For most of this
        // app's life it did nothing at all.
        guard minutes > 0 else { return "Start now. Tap to open the countdown." }
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            let lead = m > 0 ? "\(h)h \(m)m" : "\(h)h"
            return "Leave yourself \(lead). Tap to open the countdown."
        }
        return "Starts in \(minutes) min. Tap to open the countdown."
    }

    /// Replaced wholesale on every reschedule — an arm time moves whenever a
    /// step's duration changes, so patching individual alarms would leave
    /// stale ones behind.
    func cancelAllArmAlarms() {
        if !armAlarmIdentifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(armAlarmIdentifiers))
            armAlarmIdentifiers.removeAll()
        }
        // Delivered arm alerts from windows that already opened are exactly
        // the "next refresh clears whatever is left over" the chain's design
        // promises — pending-only removal never actually delivered on that.
        removeDelivered(withPrefixes: [Self.armAlarmPrefix])
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

    /// Identifier prefixes for a run's step notifications. The full scheme
    /// is "\(prefix)\(planId)-\(index)": deterministic across relaunches
    /// (planId is the plan's persisted UUID, index its renumbered position),
    /// which is what lets a resumed session's re-schedule *replace* the
    /// previous session's requests instead of stacking beside them, and
    /// what makes the prefix sweep in `cancelAllRunNotifications` able to
    /// find them at all.
    static let leadPrefix = "ontime-lead-"
    static let duePrefix = "ontime-due-"

    func scheduleRunNotifications(for plan: Plan, solution: Solution) {
        let planId = plan.uuid.uuidString
        if let old = scheduledIdentifiers[planId], !old.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(old))
        }
        var newIdentifiers: Set<String> = []
        let now = Date()
        let leadWarningMinutes = settings.defaultLeadWarningMinutes
        let blocks = plan.orderedBlocks

        for (index, block) in blocks.enumerated() {
            guard let sched = solution.blocks.first(where: { $0.index == block.order }) else { continue }
            // A walk block runs its own alarms (turnaround, heads-up, running
            // late) off measured pace, and they are the accurate ones. The
            // step notification for the same block fires at the same moment
            // saying something vaguer, so the walk used to double-alert at
            // precisely the moment it most needed to be believed.
            guard block.kind != .walk else { continue }

            let isLast = index == blocks.count - 1
            let targetDate: Date
            switch sched.constraint {
            case .hardLeaveBy(let d): targetDate = d
            case .flexAbsorbs: targetDate = sched.scheduledEnd
            }

            // 1. Lead warning (e.g. 5 min before). Off by default now, and
            //    silent when on. Every step firing twice meant a five step
            //    routine made ten sounds, and the lead warning is the half
            //    that says something you could already see: the Live
            //    Activity has been counting this exact span down on the Lock
            //    Screen the whole time.
            let leadDate = targetDate.addingTimeInterval(-Double(leadWarningMinutes * 60))
            if settings.leadWarningsEnabled && leadDate > now {
                let content = UNMutableNotificationContent()
                content.title = "\(block.name) · \(leadWarningMinutes)m left"
                content.body = Self.leadBody(
                    block: block,
                    isLast: isLast,
                    nextName: index + 1 < blocks.count ? blocks[index + 1].name : nil,
                    targetDate: targetDate
                )
                content.categoryIdentifier = Category.runStep.rawValue
                // No sound and `.passive`: it lands in Notification Center
                // for whenever you next look, without taking the screen.
                content.interruptionLevel = .passive
                content.userInfo = ["planId": planId]

                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: leadDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let identifier = "\(Self.leadPrefix)\(planId)-\(index)"
                add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                newIdentifiers.insert(identifier)
            }

            // 2. Final deadline / leave by. The one alert per step that
            //    actually asks something of you.
            if targetDate > now {
                let content = UNMutableNotificationContent()
                content.title = Self.dueTitle(block: block, isLast: isLast)
                content.body = Self.dueBody(
                    block: block,
                    isLast: isLast,
                    nextName: index + 1 < blocks.count ? blocks[index + 1].name : nil,
                    deadline: plan.deadline
                )
                content.sound = soundIfEnabled
                content.categoryIdentifier = Category.runStep.rawValue
                // Only the plan's own deadline is worth breaking Focus for.
                content.interruptionLevel = isLast ? .timeSensitive : .active
                content.userInfo = ["planId": planId]
                // One stack per run rather than a column of separate banners
                // down the Lock Screen.
                content.threadIdentifier = "\(Self.duePrefix)\(planId)"

                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: targetDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let identifier = "\(Self.duePrefix)\(planId)-\(index)"
                add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
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
        TimeFormatting.clockString(d)
    }

    // MARK: - Delegate

    /// What a notification does when it arrives with the app already open.
    ///
    /// This used to return `[.banner, .sound, .list]` unconditionally, so
    /// every alert took the top of the screen and made a noise even while
    /// you were watching the very countdown it was announcing. Now:
    ///
    /// - the plan currently on screen is silent and shows nothing at all
    ///   (`visiblePlanId`) — you are already looking at it;
    /// - nothing sounds in the foreground, ever. A sound is for getting
    ///   attention you do not have, and the app has it;
    /// - everything still goes to the list, so nothing is lost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let planId = notification.request.content.userInfo["planId"] as? String
        Task { @MainActor in
            if let planId, planId == self.visiblePlanId {
                completionHandler([])
                return
            }
            completionHandler([.banner, .list])
        }
    }

    /// A tap goes somewhere. Every branch here routes to a screen: the
    /// action buttons do their thing, and a plain tap on any of these opens
    /// the run it is about.
    ///
    /// `UNNotificationDefaultActionIdentifier` had no branch at all before,
    /// which is why "Tap to open the countdown" opened whatever tab the app
    /// happened to be on.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let planId = info["planId"] as? String
        let routineId = info["routineId"] as? String
        let action = response.actionIdentifier

        Task { @MainActor in
            switch action {
            case Action.nextStep.rawValue:
                if let planId {
                    NotificationCenter.default.post(
                        name: OnTimeShared.advanceStepNotification,
                        object: nil,
                        userInfo: ["planId": planId]
                    )
                }
            default:
                // Both the plain tap and the arm alert's "Start" button land
                // here. Neither has anything to *do* beyond showing the run:
                // `ScheduleService.catchUp` arms whatever is due on this
                // foreground regardless, on an absolute timeline, so a tap
                // fifteen minutes late still lands on the right remaining
                // time.
                var payload: [String: String] = [:]
                if let planId { payload["planId"] = planId }
                if let routineId { payload["routineId"] = routineId }
                if !payload.isEmpty {
                    NotificationCenter.default.post(
                        name: OnTimeShared.openRunNotification,
                        object: nil,
                        userInfo: payload
                    )
                }
            }
            completionHandler()
        }
    }
}
