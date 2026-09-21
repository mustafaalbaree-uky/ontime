import Foundation

/// What the Home Screen widget knows, and the file it reads it from.
///
/// **The widget does not open the SwiftData store, on purpose.** The obvious
/// design is to move the store into the App Group container and let the
/// extension run its own `@Query`. That would mean the store URL changing
/// (this app has no migration — see `OnTimeApp.openStore` — so every device
/// would come back empty once), the widget process holding a second
/// `ModelContainer` against a database the app writes to constantly, and
/// `Solver`, `Estimator` and `TravelTimeService` all having to compile into
/// an extension just so it can work out when a routine starts.
///
/// Instead the app writes down its answers. Everything the widget shows is
/// an absolute wall-clock date computed by the app, which is the same
/// principle the arm timeline already runs on: the state is a pure function
/// of the clock, so a snapshot written twenty minutes ago is still correct
/// twenty minutes later, and the widget only has to decide which rows have
/// gone by.
public struct OnTimeWidgetSnapshot: Codable, Equatable {
    public var generatedAt: Date
    /// Runs that are live right now, newest first.
    public var runs: [LiveRun]
    /// Scheduled routines' next occurrences, soonest first. Written for a
    /// week ahead, so the widget stays right even if the app is not opened
    /// for days.
    public var upcoming: [Upcoming]

    public init(generatedAt: Date = Date(), runs: [LiveRun] = [], upcoming: [Upcoming] = []) {
        self.generatedAt = generatedAt
        self.runs = runs
        self.upcoming = upcoming
    }

    public static let empty = OnTimeWidgetSnapshot()

    public struct LiveRun: Codable, Equatable, Identifiable {
        /// The plan's `uuid` string — the same identity the Live Activity
        /// and the run notifications use.
        public var id: String
        public var name: String
        public var deadline: Date
        public var stepName: String
        public var symbol: String
        public var stepIndex: Int
        public var totalSteps: Int
        /// Start of the span being counted down, so the widget can draw the
        /// same gauge the app draws without recomputing the solution.
        public var segmentStart: Date
        /// What the countdown is aimed at. Nil when the run has nothing to
        /// count to (an unsolvable sequence).
        public var target: Date?
        /// "leave by", "start", "done by" — the app's own wording.
        public var targetLabel: String
        public var isWaiting: Bool
        /// When the widget leaves this step for the next one. Nil with
        /// `target`.
        public var until: Date?
        /// The steps after this one. The app is suspended for most of a run
        /// and rewrites nothing, so the widget carries the rest of the run
        /// and `shown(at:)` picks the step the clock has reached. When this
        /// held only the current step, the widget turned red at the first
        /// boundary and counted up behind a plus sign for the rest of the
        /// routine.
        public var later: [OnTimeShownStep]

        public init(id: String, name: String, deadline: Date, stepName: String, symbol: String,
                    stepIndex: Int, totalSteps: Int, segmentStart: Date, target: Date?,
                    targetLabel: String, isWaiting: Bool, until: Date? = nil,
                    later: [OnTimeShownStep] = []) {
            self.id = id
            self.name = name
            self.deadline = deadline
            self.stepName = stepName
            self.symbol = symbol
            self.stepIndex = stepIndex
            self.totalSteps = totalSteps
            self.segmentStart = segmentStart
            self.target = target
            self.targetLabel = targetLabel
            self.isWaiting = isWaiting
            self.until = until
            self.later = later
        }

        /// A snapshot written before `until` and `later` existed still
        /// decodes. Without this, the file left by the build before would
        /// fail as a whole and the widget would show nothing scheduled
        /// until the app was next opened.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            deadline = try values.decode(Date.self, forKey: .deadline)
            stepName = try values.decode(String.self, forKey: .stepName)
            symbol = try values.decode(String.self, forKey: .symbol)
            stepIndex = try values.decode(Int.self, forKey: .stepIndex)
            totalSteps = try values.decode(Int.self, forKey: .totalSteps)
            segmentStart = try values.decode(Date.self, forKey: .segmentStart)
            target = try values.decodeIfPresent(Date.self, forKey: .target)
            targetLabel = try values.decode(String.self, forKey: .targetLabel)
            isWaiting = try values.decode(Bool.self, forKey: .isWaiting)
            until = try values.decodeIfPresent(Date.self, forKey: .until) ?? target
            later = try values.decodeIfPresent([OnTimeShownStep].self, forKey: .later) ?? []
        }

        /// The run as it stands at `date`: on the step the clock has
        /// reached, or nil once every step's time has gone by. See
        /// `OnTimeShown`.
        public func shown(at date: Date) -> LiveRun? {
            // Nothing to count to, so nothing to move on from.
            guard let until else { return deadline > date ? self : nil }
            switch OnTimeShown.resolve(until: until, later: later, now: date) {
            case .head:
                return self
            case .later(let step, let from, let rest):
                var run = self
                run.stepName = step.name
                run.symbol = step.symbol
                run.stepIndex = step.index
                run.segmentStart = from
                run.target = step.target
                run.targetLabel = step.targetLabel
                run.isWaiting = false
                run.until = step.until
                run.later = rest
                return run
            case .over:
                return nil
            }
        }
    }

    public struct Upcoming: Codable, Equatable, Identifiable {
        /// The routine's `uuid` string plus the occurrence's deadline, so a
        /// daily routine's Monday and Tuesday rows are distinct to
        /// `ForEach`.
        public var id: String
        public var name: String
        public var deadline: Date
        public var mustStartAt: Date
        public var armAt: Date
        public var stepCount: Int
        public var symbol: String

        public init(id: String, name: String, deadline: Date, mustStartAt: Date, armAt: Date,
                    stepCount: Int, symbol: String) {
            self.id = id
            self.name = name
            self.deadline = deadline
            self.mustStartAt = mustStartAt
            self.armAt = armAt
            self.stepCount = stepCount
            self.symbol = symbol
        }

        /// The routine's identity apart from which occurrence this is.
        /// `id` is built as "\(routine.uuid)-\(occurrence epoch)" (see
        /// `WidgetBridge.upcoming`), and the epoch suffix is pure digits
        /// with no dash of its own, so dropping everything from the last
        /// dash onward recovers the uuid string.
        var routineKey: String {
            guard let lastDash = id.lastIndex(of: "-") else { return id }
            return String(id[id.startIndex..<lastDash])
        }
    }

    /// The rows still ahead of `date`: an occurrence whose deadline has gone
    /// by is history, one already covered by a live run would be shown
    /// twice, and a routine with several occurrences written ahead (see
    /// `upcoming`'s doc comment) contributes only its soonest one, so a
    /// person with one or two routines does not see the same routine
    /// repeated down the list.
    public func upcoming(after date: Date, limit: Int = 6) -> [Upcoming] {
        var soonestByRoutine: [String: Upcoming] = [:]
        for item in upcoming where item.deadline > date {
            let key = item.routineKey
            if let existing = soonestByRoutine[key], existing.deadline <= item.deadline {
                continue
            }
            soonestByRoutine[key] = item
        }
        return Array(soonestByRoutine.values
            .sorted { $0.deadline < $1.deadline }
            .prefix(limit))
    }

    /// Each run on the step the clock has reached. A run with no step left
    /// is gone: it is never shown as over.
    public func liveRuns(at date: Date) -> [LiveRun] {
        runs.compactMap { $0.shown(at: date) }
    }

    /// Every moment the widget's rendering changes: a run moving to its next
    /// step, a routine's window opening, an occurrence dropping off the list.
    /// `UpNextProvider` turns these into timeline entries so the widget
    /// re-renders exactly when something has actually moved.
    public func changePoints(after date: Date) -> [Date] {
        var dates: [Date] = []
        for run in runs {
            if let until = run.until { dates.append(until) }
            dates.append(contentsOf: run.later.map(\.until))
            dates.append(run.deadline)
        }
        for item in upcoming {
            dates.append(item.armAt)
            dates.append(item.mustStartAt)
            dates.append(item.deadline)
        }
        return Set(dates.filter { $0 > date }).sorted()
    }
}

/// The App Group file the app writes and the widget reads.
public enum OnTimeWidgetStore {
    /// Declared in both targets' entitlements. The container is the only
    /// place two processes with different sandboxes can meet.
    public static let appGroup = "group.com.mammer55.ontime"
    public static let kind = "OnTimeUpNextWidget"

    private static let fileName = "widget-snapshot.json"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    public static func encode(_ snapshot: OnTimeWidgetSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Returns the bytes actually written, so the caller can compare against
    /// the last write and skip reloading the widget when nothing changed —
    /// `RunEngine` syncs roughly twenty times per step and every one of
    /// those would otherwise be a `WidgetCenter` reload.
    @discardableResult
    public static func write(_ snapshot: OnTimeWidgetSnapshot) -> Data? {
        guard let url = fileURL, let data = encode(snapshot) else { return nil }
        do {
            // Atomic: the widget process may be reading this file at any
            // moment, and a half-written JSON body decodes to nothing.
            try data.write(to: url, options: .atomic)
            return data
        } catch {
            print("OnTimeWidgetStore.write failed: \(error)")
            return nil
        }
    }

    public static func read() -> OnTimeWidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OnTimeWidgetSnapshot.self, from: data)
    }
}
