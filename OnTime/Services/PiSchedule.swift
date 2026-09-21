import Foundation

/// Hands the Pi the moments at which a Live Activity has to change while
/// this app cannot run, so the Pi can make the change by push.
///
/// Same principle as the arm timeline and the widget snapshot: everything
/// sent is an **absolute wall-clock time the app already computed**, plus the
/// exact APNs payload to deliver at that time. The Pi does no scheduling
/// math and knows nothing about routines. It holds a list and a clock. An
/// upload replaces the whole list, so the app never has to tell the Pi what
/// changed, only what is now true.
///
/// The Pi is reached on its Tailscale address. With Tailscale off on the
/// phone the upload fails, the Pi keeps whatever list it last had, and a
/// routine it knows nothing about arms the way it did before any of this
/// existed: by local notification, and on the next foreground.
@MainActor
enum PiSchedule {
    /// The Pi by its tailnet name, not its 100.x address. App Transport
    /// Security refuses plain HTTP, its exceptions are keyed by domain and
    /// cannot name an IP, and `NSAllowsLocalNetworking` does not cover
    /// Tailscale's address range. Info.plist carries the one exception, for
    /// this host only. Plain HTTP is acceptable here because the tailnet
    /// already encrypts the hop, and a certificate on the Pi would be one
    /// more thing to expire silently.
    static let endpoint = URL(string: "http://warden.taile3f2ad.ts.net:8790/schedule")!

    struct Event: Encodable {
        /// The Live Activity's `planId`. The Pi fires an id once, so an
        /// upload repeating an event already sent does not start it twice.
        let id: String
        /// Unix seconds. When to send.
        let fireAt: Double
        /// Unix seconds. A Pi that was down at `fireAt` still sends when it
        /// comes back, unless this has passed.
        let expiresAt: Double
        /// The activity's own push token, for an update or an end. nil for a
        /// start, which goes to the push to start token the upload carries.
        var token: String? = nil
        let aps: Aps
    }

    /// One future change to a running activity, as `RunEngine` projects it.
    struct RunStep: Equatable {
        let fireAt: Date
        let state: OnTimeActivityAttributes.ContentState
        /// The last step's time ran out: end the activity.
        let endsRun: Bool
    }

    /// The `aps` dictionary of an ActivityKit push, minus `timestamp`, which
    /// has to be the moment of sending and is the Pi's to fill in. A start
    /// carries the attributes and an alert; an update or an end carries
    /// neither, and an optional that is nil is left out of the JSON.
    struct Aps: Encodable {
        var event = "start"
        /// Encoded by the same default `JSONEncoder` date strategy that
        /// ActivityKit's decoder expects (seconds since 2001), which is why
        /// this is the real `ContentState` and not a hand-built dictionary.
        let contentState: OnTimeActivityAttributes.ContentState
        /// Unix seconds, unlike the dates inside `contentState`: this field
        /// belongs to APNs, not to the app's Codable type.
        var staleDate: Int? = nil
        /// Unix seconds. On an end, when the plate leaves the Lock Screen.
        /// A time already past takes it off at once.
        var dismissalDate: Int? = nil
        var attributesType: String? = nil
        var attributes: OnTimeActivityAttributes? = nil
        /// Required on a start push. No `sound`: the local arm notification
        /// at the same moment already carries the sound and the Start action.
        var alert: Alert? = nil

        struct Alert: Encodable {
            let title: String
            let body: String
        }

        enum CodingKeys: String, CodingKey {
            case event
            case contentState = "content-state"
            case staleDate = "stale-date"
            case dismissalDate = "dismissal-date"
            case attributesType = "attributes-type"
            case attributes
            case alert
        }
    }

    private struct Upload: Encodable {
        let pushToStartToken: String
        let events: [Event]
    }

    /// The body of the last upload the Pi accepted. `refreshArmAlarms` runs
    /// on every foreground and the schedule is identical for nearly all of
    /// them.
    private static var lastAccepted: Data?
    private static var armEvents: [Event] = []
    /// Projected step changes per open run, keyed by `planId`.
    private static var runSteps: [String: [RunStep]] = [:]
    /// Each live activity's own push token, keyed by `planId`. A run's steps
    /// are only uploaded once its activity has one.
    private static var activityTokens: [String: String] = [:]
    private static var isSending = false
    private static var needsResend = false

    /// How long before a boundary the Pi sends. The activity goes stale at
    /// the boundary itself and moves on from what it holds, which is one
    /// push older than what the Pi is about to deliver, and an end that
    /// lands after the boundary shows a flash of "Done" first.
    private static let pushLead: TimeInterval = 2

    /// The start push for one routine occurrence: the "until start" plate
    /// the app itself would show on arming, raised at `armAt`.
    static func armEvent(for routine: ScheduledRoutine,
                         occurrence: ScheduleService.Occurrence,
                         calendar: Calendar = .current) -> Event? {
        let blocks = routine.orderedBlocks
        guard let first = blocks.first else { return nil }
        let planId = OccurrenceIdentity.planUUID(routine: routine.uuid,
                                                 deadline: occurrence.deadline,
                                                 calendar: calendar).uuidString

        // The routine's steps, so a plate nobody updates still moves from
        // the wait into step 1 and on. Each is aimed at the deadline minus
        // everything after it with an open duration step at zero, which is
        // the schedule `mustStartAt` itself was solved from.
        var later: [OnTimeShownStep] = []
        var target = occurrence.deadline
        for (index, block) in blocks.enumerated().reversed() {
            later.insert(.init(name: block.name,
                               symbol: block.template?.symbol ?? block.kind.defaultSymbol,
                               index: index,
                               target: target,
                               targetLabel: RunEngine.shownLabel(for: block, isLast: index == blocks.count - 1),
                               until: target), at: 0)
            if !block.kind.isOpenDuration {
                target -= TimeInterval(TravelTimeService.shared.manualEstimateMinutes(for: block) * 60)
            }
        }

        let state = OnTimeActivityAttributes.ContentState(
            planName: routine.name,
            blockName: first.name,
            blockIndex: 0,
            totalBlocks: blocks.count,
            targetLeaveBy: occurrence.mustStartAt,
            segmentStart: occurrence.armAt,
            symbol: first.template?.symbol ?? first.kind.defaultSymbol,
            isWaiting: true,
            targetLabel: "Start by ",
            later: later
        )
        return Event(
            id: planId,
            fireAt: occurrence.armAt.timeIntervalSince1970,
            expiresAt: occurrence.mustStartAt.timeIntervalSince1970,
            aps: Aps(
                contentState: state,
                staleDate: Int(occurrence.mustStartAt.timeIntervalSince1970),
                attributesType: "OnTimeActivityAttributes",
                attributes: OnTimeActivityAttributes(planId: planId),
                alert: .init(title: routine.name,
                             body: Notifications.armBody(alertAt: occurrence.armAt,
                                                         mustStartAt: occurrence.mustStartAt))
            )
        )
    }

    /// Replaces the routine arm events. Run steps are untouched.
    static func publish(_ events: [Event]) {
        armEvents = events
        send()
    }

    /// Replaces one run's projected step changes. Called on every engine
    /// sync, about twenty times a step, nearly always with the same list;
    /// `send` compares the encoded body before touching the network.
    static func publishRun(planId: String, steps: [RunStep]) {
        guard runSteps[planId] != steps else { return }
        runSteps[planId] = steps
        send()
    }

    static func clearRun(planId: String) {
        guard runSteps.removeValue(forKey: planId) != nil else { return }
        activityTokens.removeValue(forKey: planId)
        send()
    }

    static func setActivityToken(planId: String, hex: String) {
        guard activityTokens[planId] != hex else { return }
        activityTokens[planId] = hex
        send()
    }

    private static func runEvents() -> [Event] {
        runSteps.flatMap { planId, steps -> [Event] in
            guard let token = activityTokens[planId] else { return [] }
            return steps.map { step in
                let at = step.fireAt.timeIntervalSince1970
                var aps = Aps(event: step.endsRun ? "end" : "update", contentState: step.state)
                if step.endsRun {
                    aps.dismissalDate = Int(at - pushLead)
                } else {
                    aps.staleDate = Int(step.state.until.timeIntervalSince1970)
                }
                // The time is part of the id: when a tap moves every later
                // boundary, these become new events rather than ones the Pi
                // believes it already sent.
                return Event(id: "\(planId)#\(step.state.blockIndex)\(step.endsRun ? "end" : "")@\(Int(at))",
                             fireAt: at - pushLead,
                             expiresAt: at + 30 * 60,
                             token: token,
                             aps: aps)
            }
        }
    }

    /// The push to start token changed, which invalidates the copy the Pi
    /// holds even though no event did.
    static func tokenChanged() {
        send()
    }

    /// What happened to the last upload, written where
    /// `devicectl device copy from` can read it. An app launched outside
    /// Xcode buffers its `print` output, so a log line is not evidence of
    /// anything; this file is.
    static let statusFileName = "pi-schedule-status.json"

    private static func note(_ outcome: String) {
        let status: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "outcome": outcome,
            "events": String(armEvents.count + runEvents().count)
        ]
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted]) else { return }
        try? data.write(to: documents.appendingPathComponent(statusFileName), options: .atomic)
    }

    /// True inside the test host. Tests build routines named "Test" and
    /// refresh the arm alarms with them; on a phone, which has a real push
    /// token, that upload would replace the real schedule on the Pi and the
    /// Pi would push "Test" into the Dynamic Island at its arm time.
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static func send() {
        guard !isRunningTests else { return }
        guard let token = PushTokens.pushToStartHex else {
            note("skipped: no push to start token yet")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let events = (armEvents + runEvents()).sorted { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }
        guard let body = try? encoder.encode(Upload(pushToStartToken: token, events: events)) else {
            note("skipped: could not encode the schedule")
            return
        }
        guard body != lastAccepted else { return }
        // One upload at a time. An upload replaces the Pi's whole list, so
        // two in flight could land out of order and leave the older list in
        // place. A change during a send is sent when that send returns.
        guard !isSending else {
            needsResend = true
            return
        }
        isSending = true

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    lastAccepted = body
                    note("accepted")
                } else {
                    note("the Pi answered \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
            } catch {
                note("failed: \(error.localizedDescription)")
            }
            isSending = false
            if needsResend {
                needsResend = false
                send()
            }
        }
    }
}
