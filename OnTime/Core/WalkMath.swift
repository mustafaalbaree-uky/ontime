import Foundation

/// The arithmetic behind a `.walk` block, with no CoreLocation and no
/// MapKit in sight so it can be tested directly. `WalkTracker` owns the
/// sensors and the routing; everything here is pure.
///
/// The question a walk block answers is not "how long is this walk," which
/// nobody knows when they set out. It is "if I turned around at this exact
/// moment, would I still be home in time." That flips a duration you have
/// to guess into a comparison you can actually make, once per GPS fix.
enum WalkMath {

    /// Pace below which a sample counts as standing still rather than
    /// walking. Waiting at a crosswalk, reading a sign, or stopping to talk
    /// should not drag the measured pace down: the return leg will be
    /// walked, not loitered, so it has to be estimated from the moving
    /// parts of the walk only. 0.4 m/s is about 0.9 mph, well under any
    /// real walking pace and well over GPS jitter while standing.
    static let movingThreshold: Double = 0.4

    /// Bounds on the measured pace, in metres per second. A GPS fix that
    /// jumps a block sideways can otherwise imply a sprint, and one that
    /// drifts can imply a crawl — either would be laundered straight into
    /// the return estimate, which is the one number the whole feature
    /// rests on. 0.6 m/s is a slow amble, 2.2 m/s is a fast walk bordering
    /// on a jog; anything outside that is instrument error, not Mustafa.
    static let minPace: Double = 0.6
    static let maxPace: Double = 2.2

    /// Fallback pace before enough of the walk has happened to measure one.
    /// Deliberately on the slow side of average: an overestimate of the
    /// return cost turns you around early, an underestimate makes you late,
    /// and only one of those two failures matters.
    static let defaultPace: Double = 1.25

    /// Smoothing factor for the running pace estimate. Low enough that one
    /// bad fix cannot move the estimate much, high enough that a genuine
    /// change (a hill, tiredness on the way out) shows up within a few
    /// minutes of walking.
    static let paceSmoothing: Double = 0.2

    /// Folds one new moving sample into the running pace estimate, or
    /// returns the previous estimate unchanged when the sample says you
    /// were standing still. `nil` in means nothing has been measured yet,
    /// in which case the first moving sample is taken whole.
    static func updatedPace(previous: Double?, sampleMetersPerSecond: Double) -> Double? {
        guard sampleMetersPerSecond >= movingThreshold else { return previous }
        let clamped = min(max(sampleMetersPerSecond, minPace), maxPace)
        guard let previous else { return clamped }
        return previous + paceSmoothing * (clamped - previous)
    }

    /// Where a return estimate came from, so the screen can say so rather
    /// than presenting every number with the same false confidence.
    enum ReturnSource: String, Equatable, Sendable {
        /// A MapKit walking route home, timed at the pace actually measured
        /// on this walk. The best of the three: the map knows the shortest
        /// way back, which is rarely the way you came, and the pace is
        /// yours rather than the map's generic walker.
        case routedAtMyPace
        /// A MapKit walking route home, timed by MapKit, because not enough
        /// walking has happened yet to measure a pace.
        case routed
        /// No route available (no signal, off-road, routing failed), so the
        /// estimate is the path already walked, retraced at the measured
        /// pace. This is the assumption Mustafa described: walk back the
        /// way you came, and the return leg costs what the outbound leg
        /// cost.
        case retrace
    }

    struct ReturnEstimate: Equatable, Sendable {
        /// Seconds to get home, safety margin already applied.
        var seconds: TimeInterval
        /// Seconds before the margin, for the screen to show the raw number
        /// beside the padded one.
        var rawSeconds: TimeInterval
        var source: ReturnSource
    }

    /// The cost of getting home from where you are standing.
    ///
    /// `routeDistanceMeters` / `routeSeconds` are MapKit's walking route
    /// home; `retraceSeconds` is what it would cost to walk back the way
    /// you came. The order of preference is deliberate: distance is the
    /// thing a map is genuinely authoritative about, while duration is a
    /// guess about the walker, and this app has the walker. So a route is
    /// re-timed at the measured pace whenever there is one, and MapKit's
    /// own duration is only used before any pace has been measured.
    ///
    /// `safetyFraction` pads the result. Being early costs nothing; being
    /// late costs the thing the deadline was for. That asymmetry is the
    /// entire justification for padding an estimate that is already
    /// unbiased.
    static func returnEstimate(
        routeDistanceMeters: Double?,
        routeSeconds: TimeInterval?,
        retraceSeconds: TimeInterval,
        measuredPace: Double?,
        safetyFraction: Double
    ) -> ReturnEstimate {
        let raw: TimeInterval
        let source: ReturnSource

        if let routeDistanceMeters, let measuredPace, measuredPace > 0 {
            raw = routeDistanceMeters / measuredPace
            source = .routedAtMyPace
        } else if let routeSeconds {
            raw = routeSeconds
            source = .routed
        } else {
            raw = retraceSeconds
            source = .retrace
        }

        // A negative fraction would shrink the padded estimate below the
        // raw one, inverting the whole "late costs more than early"
        // justification for padding at all.
        let fraction = max(0, safetyFraction)
        return ReturnEstimate(
            seconds: raw * (1 + fraction),
            rawSeconds: raw,
            source: source
        )
    }

    /// The moment to turn around: the latest instant at which starting back
    /// still gets you home by `homeBy`.
    ///
    /// This slides as you walk. Heading away from home pushes it earlier;
    /// heading back, or finding a shortcut, pushes it later. That is why it
    /// is recomputed on every fix rather than fixed at the start of the
    /// walk, and why the alarm behind it is re-armed each time rather than
    /// set once.
    static func turnaroundTime(homeBy: Date, returnSeconds: TimeInterval) -> Date {
        homeBy.addingTimeInterval(-returnSeconds)
    }

    /// How much walking-away time is left before the return cost eats the
    /// whole budget. Negative means you are already past the point of
    /// turning around and will be late unless the way back is shorter than
    /// estimated.
    static func slack(now: Date, homeBy: Date, returnSeconds: TimeInterval) -> TimeInterval {
        homeBy.timeIntervalSince(now) - returnSeconds
    }

    /// How much further out you can still go, in time.
    ///
    /// Half the slack, because every additional minute spent walking away
    /// has to be paid for twice: once to walk it, once to walk back over
    /// it. This is the retrace assumption, and it is deliberately the
    /// pessimistic one even when a route home is available — continuing
    /// outward along a loop sometimes costs less than double, but it never
    /// costs more, so half the slack is a floor rather than a guess.
    ///
    /// It is also the number worth looking at mid-walk. "Turn around now"
    /// is only useful at the moment it fires; "you can go nine more
    /// minutes" is useful for the whole hour before that, when there is
    /// still a decision to make about which way to go.
    static func remainingOutbound(slack: TimeInterval) -> TimeInterval {
        max(0, slack / 2)
    }

    /// Which side of the walk you are on. The walk does not end when you
    /// turn around, but almost everything the screen says changes at that
    /// point: outbound the question is how much further you can go,
    /// homebound it is whether you are going to make it.
    enum Phase: String, Equatable, Sendable, Codable {
        case outbound
        case returning
    }

    /// Whether a fix says you are getting closer to home. Used to notice a
    /// turnaround that was never announced by a tap — the phone stays in a
    /// pocket, and a feature that depends on being told when you turned
    /// around would be wrong most of the time.
    ///
    /// Requires a sustained decrease rather than a single closer fix, since
    /// GPS noise alone moves you tens of metres either way while standing
    /// still. `sustainedApproachMeters` is the total closing distance that
    /// counts as a real turnaround.
    static let sustainedApproachMeters: Double = 150

    /// When the walk is projected to reach home, given the current return
    /// estimate. On the way back this is the number that matters, and it is
    /// compared against `homeBy` rather than against the turnaround time.
    static func projectedArrival(now: Date, returnSeconds: TimeInterval) -> Date {
        now.addingTimeInterval(returnSeconds)
    }

    // MARK: Alarm policy

    /// What to do with one pending alarm.
    enum AlarmDirective: Equatable {
        /// Leave whatever is pending exactly as it is.
        case keep
        /// Remove the pending request.
        case cancel
        /// Schedule (or replace) the request at this absolute time.
        case arm(Date)
        /// Deliver immediately — the moment the alarm was for has already
        /// passed. A calendar request at a past date is refused by the
        /// system, and cancelling first then failing to arm is exactly how
        /// the turnaround alert used to silently disappear.
        case fireNow
    }

    struct AlarmDecision: Equatable {
        var turnaround: AlarmDirective
        var headsUp: AlarmDirective
        var late: AlarmDirective
    }

    /// The walk's whole alarm policy as a pure function, so the two bugs it
    /// replaced stay testable: a turnaround estimate that slipped into the
    /// past used to cancel the pending alarm and arm nothing, and the
    /// "Running late" alarm was re-armed at now plus 30 seconds on every
    /// one-second tick, so while the app was alive (which background
    /// location keeps true for the whole walk) it was perpetually deferred
    /// and never fired.
    ///
    /// `WalkTracker` owns the state this reads (`armedTurnaround`,
    /// `pastTurnaroundFired`, `lateAlarmArmed`) and applies the directives.
    static func alarmDecision(
        phase: Phase,
        now: Date,
        homeBy: Date,
        turnaroundAt: Date,
        headsUpLead: TimeInterval,
        projectedArrival: Date,
        armedTurnaround: Date?,
        pastTurnaroundFired: Bool,
        lateAlarmArmed: Bool,
        force: Bool
    ) -> AlarmDecision {
        if phase == .returning {
            // Nothing to turn around for; the question is whether the
            // projected arrival has slipped past the deadline. Armed once
            // per crossing, never re-deferred, with a one-minute hysteresis
            // band so a pace estimate wobbling around the boundary does not
            // arm and cancel every few seconds.
            if projectedArrival > homeBy {
                let late: AlarmDirective = lateAlarmArmed ? .keep : .arm(now.addingTimeInterval(30))
                return AlarmDecision(turnaround: .keep, headsUp: .keep, late: late)
            }
            let backOnTime = projectedArrival <= homeBy.addingTimeInterval(-60)
            return AlarmDecision(
                turnaround: .keep,
                headsUp: .keep,
                late: lateAlarmArmed && backOnTime ? .cancel : .keep
            )
        }

        // Outbound.
        if turnaroundAt <= now {
            // Past the point of turning around: say so immediately, once
            // per crossing, instead of scheduling into the past (refused)
            // or every tick (spam).
            guard !pastTurnaroundFired else {
                return AlarmDecision(turnaround: .keep, headsUp: .keep, late: .keep)
            }
            return AlarmDecision(turnaround: .fireNow, headsUp: .cancel, late: .keep)
        }
        if !force, let armed = armedTurnaround, abs(armed.timeIntervalSince(turnaroundAt)) < 30 {
            return AlarmDecision(turnaround: .keep, headsUp: .keep, late: .keep)
        }
        return AlarmDecision(
            turnaround: .arm(turnaroundAt),
            headsUp: .arm(turnaroundAt.addingTimeInterval(-headsUpLead)),
            late: .keep
        )
    }
}
