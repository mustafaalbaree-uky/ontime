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
    static let endpoint = URL(string: "http://100.88.112.8:8790/schedule")!

    struct Event: Encodable {
        /// The Live Activity's `planId`. The Pi fires an id once, so an
        /// upload repeating an event already sent does not start it twice.
        let id: String
        /// Unix seconds. When to send.
        let fireAt: Double
        /// Unix seconds. A Pi that was down at `fireAt` still sends when it
        /// comes back, unless this has passed.
        let expiresAt: Double
        let aps: Aps
    }

    /// The `aps` dictionary of an ActivityKit "start" push, minus
    /// `timestamp`, which has to be the moment of sending and is the Pi's to
    /// fill in.
    struct Aps: Encodable {
        let event = "start"
        /// Encoded by the same default `JSONEncoder` date strategy that
        /// ActivityKit's decoder expects (seconds since 2001), which is why
        /// this is the real `ContentState` and not a hand-built dictionary.
        let contentState: OnTimeActivityAttributes.ContentState
        /// Unix seconds, unlike the dates inside `contentState`: this field
        /// belongs to APNs, not to the app's Codable type.
        let staleDate: Int
        let attributesType = "OnTimeActivityAttributes"
        let attributes: OnTimeActivityAttributes
        /// Required on a start push. No `sound`: the local arm notification
        /// at the same moment already carries the sound and the Start action.
        let alert: Alert

        struct Alert: Encodable {
            let title: String
            let body: String
        }

        enum CodingKeys: String, CodingKey {
            case event
            case contentState = "content-state"
            case staleDate = "stale-date"
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
    private static var lastEvents: [Event] = []

    /// The start push for one routine occurrence: the "until start" plate
    /// the app itself would show on arming, raised at `armAt`.
    static func armEvent(for routine: ScheduledRoutine,
                         occurrence: ScheduleService.Occurrence,
                         calendar: Calendar = .current) -> Event? {
        guard let first = routine.orderedBlocks.first else { return nil }
        let planId = OccurrenceIdentity.planUUID(routine: routine.uuid,
                                                 deadline: occurrence.deadline,
                                                 calendar: calendar).uuidString
        let state = OnTimeActivityAttributes.ContentState(
            planName: routine.name,
            blockName: first.name,
            blockIndex: 0,
            totalBlocks: routine.orderedBlocks.count,
            targetLeaveBy: occurrence.mustStartAt,
            segmentStart: occurrence.armAt,
            symbol: first.template?.symbol ?? first.kind.defaultSymbol,
            isWaiting: true,
            targetLabel: "Start by ",
            startsRunAtTarget: true
        )
        return Event(
            id: planId,
            fireAt: occurrence.armAt.timeIntervalSince1970,
            expiresAt: occurrence.mustStartAt.timeIntervalSince1970,
            aps: Aps(
                contentState: state,
                staleDate: Int(occurrence.mustStartAt.timeIntervalSince1970),
                attributes: OnTimeActivityAttributes(planId: planId),
                alert: .init(title: routine.name,
                             body: Notifications.armBody(alertAt: occurrence.armAt,
                                                         mustStartAt: occurrence.mustStartAt))
            )
        )
    }

    /// Replaces the Pi's whole list with `events`.
    static func publish(_ events: [Event]) {
        lastEvents = events
        send()
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
            "events": String(lastEvents.count)
        ]
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted]) else { return }
        try? data.write(to: documents.appendingPathComponent(statusFileName), options: .atomic)
    }

    private static func send() {
        guard let token = PushTokens.pushToStartHex else {
            note("skipped: no push to start token yet")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(Upload(pushToStartToken: token, events: lastEvents)) else {
            note("skipped: could not encode the schedule")
            return
        }
        guard body != lastAccepted else { return }

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
        }
    }
}
