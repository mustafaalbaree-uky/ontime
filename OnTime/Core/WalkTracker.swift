import Foundation
import CoreLocation
import MapKit
import Observation
import UserNotifications

/// Watches one live `.walk` block: where you are, how fast you are actually
/// moving, what it would cost to get home from here, and therefore when you
/// have to turn around.
///
/// Separate from `LocationService` on purpose. That one is a one-shot fix
/// service built around continuations — ask, get a coordinate, resume the
/// waiters — and it is deliberately stingy about how often it wakes the
/// GPS, because everything else in the app only ever needs to know where
/// you are at the instant a drive block is resolved. A walk is the opposite
/// shape: a continuous stream for as long as the block is active, in the
/// background, with the screen off. Threading that through the waiter model
/// would have meant one class with two incompatible lifecycles.
///
/// **The alarm does not depend on this object staying alive.** Every time
/// the estimate moves, the turnaround time is re-armed as a local
/// notification at an absolute clock time (`Notifications.armAlarm`). If
/// iOS suspends the app, kills it, or the GPS goes silent in a valley, the
/// last alarm armed still fires. Location updates make the alarm *more*
/// accurate; they are not what makes it fire. That is the whole safety
/// argument for a feature whose failure mode is missing a prayer.
@MainActor
@Observable
final class WalkTracker: NSObject, CLLocationManagerDelegate {
    static let shared = WalkTracker()

    // MARK: Identifiers

    /// One id per alarm so re-arming replaces rather than piles up —
    /// `armAlarm` removes the pending request with the same id first.
    static let turnaroundAlarmID = "ontime-walk-turnaround"
    static let headsUpAlarmID = "ontime-walk-headsup"
    static let lateAlarmID = "ontime-walk-late"

    // MARK: Live state

    private(set) var isActive = false
    private(set) var startedAt: Date?
    /// The moment the walk block must be over: the solver's `leaveBy` for
    /// this block, which is the deadline minus everything that comes after
    /// it. For Mustafa's case (8:00 prayer, a 10 minute block before it)
    /// this is 7:50, and nothing here computes that — `RunEngine` hands it
    /// over and re-hands it whenever the solution changes.
    private(set) var homeBy: Date?
    private(set) var homeName: String = "home"
    private(set) var homeCoordinate: CLLocationCoordinate2D?

    private(set) var phase: WalkMath.Phase = .outbound
    private(set) var pace: Double?
    private(set) var pathDistanceMeters: Double = 0
    private(set) var lastFix: CLLocation?
    private(set) var lastFixAt: Date?
    /// Straight-line metres to home at the last fix. Also the basis for
    /// noticing an unannounced turnaround.
    private(set) var directDistanceMeters: Double?
    private(set) var farthestDistanceMeters: Double = 0

    private(set) var routeDistanceMeters: Double?
    private(set) var routeSeconds: TimeInterval?
    private(set) var routeFetchedAt: Date?
    private(set) var routeError: String?

    /// Set when the walk cannot be tracked at all (location refused). The
    /// block still works — it falls back to the retrace estimate driven by
    /// elapsed time — but the screen has to say so rather than quietly
    /// showing numbers built on nothing.
    private(set) var unavailableReason: String?
    /// A transient CoreLocation failure mid-walk (signal lost, denied while
    /// out). Distinct from `routeError`, which means "MapKit could not
    /// route home" — the two have different remedies and used to be
    /// written into the same field.
    private(set) var locationError: String?
    /// True when notification authorization is denied, checked at `begin`.
    /// The entire safety argument of this feature rests on the armed alarm
    /// firing; with notifications off every `armAlarm` call succeeds
    /// silently while delivering nothing, so the screen has to say so.
    private(set) var notificationsDenied = false

    /// Which `Run` this walk belongs to. `RunEngine.cancel` and the
    /// finished-run teardown used to call `end()` unconditionally, so
    /// finishing any run killed a different concurrent run's active walk
    /// and its armed turnaround alarm.
    private(set) var ownerRunId: UUID?

    // MARK: Private

    private let manager = CLLocationManager()
    private var routeTask: Task<Void, Never>?
    private var routeGeneration = 0
    private var routeOrigin: CLLocationCoordinate2D?
    /// Turnaround time the alarms were last armed against, so a re-arm only
    /// happens when the estimate has actually moved. Without this the
    /// notification centre would be handed a new request on every fix.
    private var armedTurnaround: Date?
    /// One immediate "turn around now" per crossing into the past — see
    /// `WalkMath.alarmDecision`.
    private var pastTurnaroundFired = false
    /// The returning-phase late alarm is armed once per crossing, never
    /// re-deferred — see `WalkMath.alarmDecision`.
    private var lateAlarmArmed = false

    /// Refetch the route home once you have moved this far from wherever it
    /// was last computed. Distance-based rather than purely time-based
    /// because a route that is two minutes old is perfectly good if you
    /// have not moved, and useless if you have crossed a river.
    private static let routeRefreshDistance: Double = 150
    private static let routeMaxAge: TimeInterval = 180
    /// Below this, "get home" is not a routing problem any more.
    private static let arrivedRadius: Double = 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // Ten metres of movement before a new fix. Fine enough that the
        // path length is honest over a mile of walking, coarse enough that
        // standing at a crosswalk does not generate a fix a second.
        manager.distanceFilter = 10
        manager.activityType = .fitness
        // Automatic pausing is deliberately OFF, and must stay off: a
        // paused manager in the background never resumes on its own, so
        // one long rest on a bench would leave the rest of the walk
        // untracked and the alarm frozen at whatever was last armed. The
        // battery cost is the price of the safety argument.
        manager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: Lifecycle

    /// Begins tracking. Safe to call again for an already-running walk
    /// (`RunEngine` calls it on every solution change to keep `homeBy`
    /// current), in which case only the deadline and destination update and
    /// the measured path is left alone.
    func begin(homeBy: Date, home: Place?, owner: UUID? = nil, now: Date = Date()) {
        self.homeBy = homeBy
        if let home, !home.isCurrentLocation {
            homeCoordinate = CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude)
            homeName = home.name
        } else if !isActive {
            // A fresh walk with no concrete destination must not inherit
            // the previous walk's home point — arrival detection, the
            // automatic phase flip, and the route home would all be
            // computed against somewhere else entirely.
            homeCoordinate = nil
            homeName = "home"
        }

        guard !isActive else {
            if let owner { ownerRunId = owner }
            rearmAlarmsIfNeeded()
            return
        }

        isActive = true
        ownerRunId = owner
        startedAt = now
        phase = .outbound
        pace = nil
        pathDistanceMeters = 0
        lastFix = nil
        lastFixAt = nil
        directDistanceMeters = nil
        farthestDistanceMeters = 0
        routeDistanceMeters = nil
        routeSeconds = nil
        routeFetchedAt = nil
        routeError = nil
        routeOrigin = nil
        armedTurnaround = nil
        pastTurnaroundFired = false
        lateAlarmArmed = false
        unavailableReason = nil
        locationError = nil
        refreshNotificationAuthorization()

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            unavailableReason = LocationError.denied.errorDescription
        default:
            startUpdates()
        }

        // Arm immediately off the retrace estimate, before a single fix has
        // landed. A walk that begins in a parking garage with no signal
        // still gets an alarm; it is just a worse one until the GPS speaks.
        rearmAlarmsIfNeeded(force: true)
    }

    /// Ends the walk. Pass the run's id when calling from run teardown: with
    /// more than one run open at once, only the walk's own run may end it —
    /// a mismatched owner is a no-op instead of killing another run's
    /// tracking and its armed turnaround alarm.
    func end(for owner: UUID? = nil) {
        guard isActive else { return }
        if let owner, let current = ownerRunId, current != owner { return }
        isActive = false
        ownerRunId = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        routeTask?.cancel()
        routeTask = nil
        Notifications.shared.cancelAlarms(ids: [
            Self.turnaroundAlarmID, Self.headsUpAlarmID, Self.lateAlarmID
        ])
        armedTurnaround = nil
        pastTurnaroundFired = false
        lateAlarmArmed = false
    }

    private func refreshNotificationAuthorization() {
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self.notificationsDenied = settings.authorizationStatus == .denied
        }
    }

    private func startUpdates() {
        // Background updates on a "when in use" grant are allowed as long as
        // they were started while the app was in the foreground, which is
        // always true here: a walk begins by tapping into the step. iOS
        // shows the blue location pill for the duration, which is honest
        // and is also a useful reminder that the walk is being watched.
        // Requesting "always" instead would buy nothing except a scarier
        // permission prompt.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        manager.requestLocation()
    }

    /// Recomputes and re-arms off the clock alone, with no new fix.
    ///
    /// Not redundant with the re-arm inside `ingest`. With no GPS at all —
    /// permission refused, or a long stretch with no signal — no fix ever
    /// arrives, so nothing else would ever revise the alarm armed at the
    /// start of the walk, and the retrace fallback would sit pointing at
    /// the deadline itself instead of walking backwards toward the halfway
    /// point as the walk went on. `RunEngine`'s one-second tick drives this
    /// so the fallback stays honest without a single location update.
    func tick() {
        guard isActive else { return }
        rearmAlarmsIfNeeded()
    }

    // MARK: Phase

    /// Declares the turnaround by hand. The tap exists because a person
    /// knows they have turned around a good while before the GPS can prove
    /// it, and the sooner the phase flips, the sooner the screen switches
    /// from "how much further" to "will I make it."
    func markReturning() {
        guard phase != .returning else { return }
        phase = .returning
        Notifications.shared.cancelAlarms(ids: [Self.turnaroundAlarmID, Self.headsUpAlarmID])
        armedTurnaround = nil
        pastTurnaroundFired = false
        refreshRouteIfStale(force: true)
        rearmAlarmsIfNeeded(force: true)
    }

    func markOutbound() {
        guard phase != .outbound else { return }
        phase = .outbound
        farthestDistanceMeters = directDistanceMeters ?? 0
        Notifications.shared.cancelAlarms(ids: [Self.lateAlarmID])
        lateAlarmArmed = false
        rearmAlarmsIfNeeded(force: true)
    }

    // MARK: Derived numbers

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// The retrace fallback: the path already walked, at the measured pace.
    ///
    /// Path distance rather than elapsed time is what makes this better than
    /// the "however long you have been out, double it" rule Mustafa
    /// described. Ten minutes spent sitting on a bench is ten minutes of
    /// elapsed time and zero metres of walking home, so counting elapsed
    /// time would turn you around a full ten minutes early for a rest you
    /// already took. Before any fix arrives there is no path to measure, so
    /// it does fall back to exactly that doubling rule.
    private var retraceSeconds: Double {
        guard pathDistanceMeters > 0 else { return elapsed }
        return pathDistanceMeters / (pace ?? WalkMath.defaultPace)
    }

    var estimate: WalkMath.ReturnEstimate {
        // Standing on the doorstep: the answer is zero, not whatever the
        // router says about walking around the block.
        if let direct = directDistanceMeters, direct <= Self.arrivedRadius {
            return WalkMath.ReturnEstimate(seconds: 0, rawSeconds: 0, source: .routedAtMyPace)
        }
        return WalkMath.returnEstimate(
            routeDistanceMeters: routeDistanceMeters,
            routeSeconds: routeSeconds,
            retraceSeconds: retraceSeconds,
            measuredPace: pace,
            safetyFraction: AppSettings.shared.walkSafetyFraction
        )
    }

    var turnaroundAt: Date? {
        guard let homeBy else { return nil }
        return WalkMath.turnaroundTime(homeBy: homeBy, returnSeconds: estimate.seconds)
    }

    func slack(now: Date = Date()) -> TimeInterval? {
        guard let homeBy else { return nil }
        return WalkMath.slack(now: now, homeBy: homeBy, returnSeconds: estimate.seconds)
    }

    func remainingOutbound(now: Date = Date()) -> TimeInterval? {
        guard let homeBy else { return nil }
        // Halved from the *unpadded* slack: the halving rule is itself a
        // documented pessimistic floor, so halving the safety-padded slack
        // counted the same margin twice against the outbound budget. The
        // alarm and the headline countdown still use the padded estimate.
        let raw = WalkMath.slack(now: now, homeBy: homeBy, returnSeconds: estimate.rawSeconds)
        return WalkMath.remainingOutbound(slack: raw)
    }

    func projectedArrival(now: Date = Date()) -> Date {
        WalkMath.projectedArrival(now: now, returnSeconds: estimate.seconds)
    }

    /// The one time the Live Activity and the header count down to. It is
    /// the turnaround while heading out, and the be-home-by time once
    /// heading back — the same widget, the same ring, two different
    /// questions, which is why nothing in `OnTimeWidget` needed to learn
    /// about walks at all.
    var activityTarget: Date? {
        phase == .returning ? homeBy : turnaroundAt
    }

    var activityLabel: String {
        phase == .returning ? "Home by " : "Turn back by "
    }

    // MARK: Alarms

    /// Re-arms the walk alarms against the current estimate. The policy
    /// itself lives in `WalkMath.alarmDecision`, pure and tested; this just
    /// gathers the inputs and applies the directives.
    private func rearmAlarmsIfNeeded(force: Bool = false) {
        guard isActive, let homeBy, let turnaround = turnaroundAt else { return }

        let now = Date()
        let decision = WalkMath.alarmDecision(
            phase: phase,
            now: now,
            homeBy: homeBy,
            turnaroundAt: turnaround,
            headsUpLead: Double(AppSettings.shared.walkHeadsUpMinutes * 60),
            projectedArrival: projectedArrival(now: now),
            armedTurnaround: armedTurnaround,
            pastTurnaroundFired: pastTurnaroundFired,
            lateAlarmArmed: lateAlarmArmed,
            force: force
        )

        let back = Int((estimate.seconds / 60).rounded())
        let homePhrase = homeName == "home" ? "home" : "at \(homeName)"

        switch decision.turnaround {
        case .keep:
            break
        case .cancel:
            Notifications.shared.cancelAlarms(ids: [Self.turnaroundAlarmID])
            armedTurnaround = nil
        case .arm(let at):
            armedTurnaround = turnaround
            pastTurnaroundFired = false
            Notifications.shared.armAlarm(
                id: Self.turnaroundAlarmID,
                fireAt: at,
                title: "Turn around now",
                body: "\(back) min back. That puts you \(homePhrase) by \(TimeFormatting.clockString(homeBy))."
            )
        case .fireNow:
            pastTurnaroundFired = true
            armedTurnaround = turnaround
            Notifications.shared.deliverAlarmNow(
                id: Self.turnaroundAlarmID,
                title: "Turn around now",
                body: "You're past the turnaround point. \(back) min back puts you \(homePhrase) after \(TimeFormatting.clockString(homeBy))."
            )
        }

        switch decision.headsUp {
        case .keep:
            break
        case .cancel, .fireNow:
            Notifications.shared.cancelAlarms(ids: [Self.headsUpAlarmID])
        case .arm(let at):
            Notifications.shared.armAlarm(
                id: Self.headsUpAlarmID,
                fireAt: at,
                title: "Turn back soon",
                body: "About \(AppSettings.shared.walkHeadsUpMinutes) min of walking out left. \(back) min back from there."
            )
        }

        switch decision.late {
        case .keep:
            break
        case .cancel:
            Notifications.shared.cancelAlarms(ids: [Self.lateAlarmID])
            lateAlarmArmed = false
        case .arm(let at):
            lateAlarmArmed = true
            let over = Int((projectedArrival(now: now).timeIntervalSince(homeBy) / 60).rounded(.up))
            Notifications.shared.armAlarm(
                id: Self.lateAlarmID,
                fireAt: at,
                title: "Running late",
                body: "At your pace you get \(homeName == "home" ? "home" : "to \(homeName)") about \(over) min after \(TimeFormatting.clockString(homeBy))."
            )
        case .fireNow:
            break
        }
    }

    // MARK: Routing

    /// Asks MapKit for the walking route home and keeps only its
    /// *distance* as the primary output.
    ///
    /// The distance is the part a map is genuinely authoritative about: it
    /// knows the footbridge, the cut-through, and the fact that the direct
    /// line crosses a highway. The duration is a guess about a generic
    /// walker, and this app is standing next to a specific one whose pace
    /// it has been measuring for the last twenty minutes. So the route
    /// supplies the metres and the walk supplies the seconds per metre.
    /// `expectedTravelTime` is still kept, as the answer before enough
    /// walking has happened to measure anything.
    private func refreshRouteIfStale(force: Bool = false) {
        guard isActive, let here = lastFix?.coordinate, let home = homeCoordinate else { return }
        if force {
            // A forced refetch (phase just flipped, the return leg needs a
            // fresh route) must not be silently skipped because an outbound
            // request happens to be in flight — cancel it and go again.
            routeTask?.cancel()
            routeTask = nil
        }
        guard routeTask == nil else { return }

        if !force, let origin = routeOrigin, let fetchedAt = routeFetchedAt {
            let moved = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: here.latitude, longitude: here.longitude))
            if moved < Self.routeRefreshDistance,
               Date().timeIntervalSince(fetchedAt) < Self.routeMaxAge {
                return
            }
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: here))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: home))
        request.transportType = .walking

        routeGeneration += 1
        let generation = routeGeneration
        routeTask = Task { [weak self] in
            // The cleanup must only clear the handle for its *own* task —
            // a cancelled task's deferred hop would otherwise nil out the
            // replacement task's handle a moment after force created it.
            defer { Task { @MainActor in
                if let self, self.routeGeneration == generation { self.routeTask = nil }
            } }
            do {
                let response = try await MKDirections(request: request).calculateETA()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.isActive, self.routeGeneration == generation else { return }
                    self.routeDistanceMeters = response.distance
                    self.routeSeconds = response.expectedTravelTime
                    self.routeFetchedAt = Date()
                    self.routeOrigin = here
                    self.routeError = nil
                    self.rearmAlarmsIfNeeded()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    // Deliberately does not clear the last good route: a
                    // route from 200 metres back is a far better answer
                    // than falling all the way to retracing, and the
                    // staleness is bounded by `routeRefreshDistance`.
                    self.routeError = error.localizedDescription
                }
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            guard self.isActive else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.unavailableReason = nil
                self.startUpdates()
            case .denied, .restricted:
                self.unavailableReason = LocationError.denied.errorDescription
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        let fixes = locs
        Task { @MainActor in self.ingest(fixes) }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            // Not fatal: the pre-armed alarm still stands, and the retrace
            // estimate still works off whatever path was measured before
            // the signal went. Recorded as a *location* failure — this used
            // to be written into `routeError`, so the screen blamed MapKit
            // routing for a GPS outage, which has a different remedy.
            self.locationError = message
        }
    }

    @MainActor
    private func ingest(_ fixes: [CLLocation]) {
        guard isActive else { return }
        for fix in fixes {
            // Reject the fixes CoreLocation itself flags as untrustworthy
            // before they reach the pace estimate. A 500 metre accuracy
            // reading dropped into the path length is indistinguishable
            // from actually walking 500 metres.
            guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 50 else { continue }

            if let previous = lastFix {
                let delta = fix.distance(from: previous)
                let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0, delta.isFinite {
                    pathDistanceMeters += delta
                    // `fix.speed` is the instantaneous doppler speed where
                    // the hardware can supply one, which is steadier than
                    // dividing two noisy positions. Fall back to the
                    // positional derivative where it cannot.
                    let sample = fix.speed >= 0 ? fix.speed : delta / dt
                    pace = WalkMath.updatedPace(previous: pace, sampleMetersPerSecond: sample)
                }
            }
            lastFix = fix
            lastFixAt = fix.timestamp
            locationError = nil
        }

        if let home = homeCoordinate, let here = lastFix {
            let distance = here.distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
            directDistanceMeters = distance
            farthestDistanceMeters = max(farthestDistanceMeters, distance)

            // Notice a turnaround nobody announced. The phone spends the
            // walk in a pocket, so a feature that only flipped phase on a
            // tap would spend most of its life in the wrong phase.
            if phase == .outbound,
               farthestDistanceMeters - distance >= WalkMath.sustainedApproachMeters {
                markReturning()
            }
        }

        refreshRouteIfStale()
        rearmAlarmsIfNeeded()
    }
}
