import Foundation
import CoreLocation
import Observation

enum LocationError: LocalizedError {
    case denied
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied: return "Location access is off for On Time. Turn it on in iOS Settings → Privacy → Location Services."
        case .timedOut: return "Couldn't get a GPS fix in time."
        case .failed(let message): return message
        }
    }
}

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager: CLLocationManager
    private let settings = AppSettings.shared

    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var revision = 0
    /// True while a one-shot fix is in flight, so a view can show that the
    /// tap actually did something instead of silently writing a label.
    private(set) var isAcquiring = false
    /// Human-readable name for the last fix (reverse-geocoded, best effort).
    /// This is the piece that makes "Current Location" legible: without it a
    /// tap on the chip is indistinguishable from a tap that did nothing.
    private(set) var lastFixDescription: String?

    /// Everyone waiting on the current one-shot fix, keyed so a single
    /// waiter can be timed out or cancelled without disturbing the others.
    /// A collection, not one optional: `requestLocation()` from a
    /// `.notDetermined` state has to go through the authorization prompt
    /// first, so several callers pile up before any fix arrives — and
    /// resuming a continuation twice is a crash, not a warning.
    ///
    /// Everything that touches this is `@MainActor`; the raw delegate
    /// callbacks below are the only non-isolated entry points and they do
    /// nothing but hop here.
    @ObservationIgnored @MainActor private var waiters: [UUID: CheckedContinuation<CLLocationCoordinate2D, Error>] = [:]
    @ObservationIgnored private var geocoder = CLGeocoder()

    override init() {
        // CoreLocation delivers delegate callbacks on the run loop of the
        // thread the manager was created on; created off the main thread
        // there may be no running run loop and nothing is ever delivered —
        // every fix request would just time out, looking like a GPS outage.
        // The first touch of this singleton can come from a background ETA
        // resolution, so pin the manager's creation to main explicitly.
        if Thread.isMainThread {
            manager = CLLocationManager()
        } else {
            manager = DispatchQueue.main.sync { CLLocationManager() }
        }
        super.init()
        manager.delegate = self
        // A kilometer of slop is fine for prayer times but wrong for a drive
        // origin — it can put you on a different road, and the whole point of
        // a "Current Location" origin is that the ETA starts from where you
        // actually are. `requestLocation()` is one-shot, so the extra
        // precision costs effectively nothing in battery.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus
    }

    // MARK: Location

    @MainActor
    func requestLocation() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            isAcquiring = true
            manager.requestLocation()
        }
    }

    /// Whether the stored coordinate is recent enough to route from.
    func hasFix(fresherThan maxAge: TimeInterval) -> Bool {
        guard settings.hasRealLocation, let at = settings.lastFixAt else { return false }
        return Date().timeIntervalSince(at) <= maxAge
    }

    /// The current coordinate, refreshing it from the GPS if what we have is
    /// older than `maxAge`. This is what makes a "Current Location" origin
    /// mean *now* rather than wherever the app last happened to look — a
    /// stale coordinate silently routes from this morning's parking spot.
    @MainActor
    func currentCoordinate(maxAge: TimeInterval = 120, timeout: TimeInterval = 10) async throws -> CLLocationCoordinate2D {
        if hasFix(fresherThan: maxAge) {
            return CLLocationCoordinate2D(latitude: settings.lastLatitude, longitude: settings.lastLongitude)
        }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw LocationError.denied
        default:
            break
        }

        let id = UUID()
        // The timeout is armed as a sibling task that *finishes this
        // waiter*, rather than as a racing task-group branch: a bare
        // `withCheckedThrowingContinuation` ignores cancellation, and a task
        // group can't leave its scope until every child returns — so a
        // group-based timeout would fire on paper while `currentCoordinate`
        // kept blocking until CoreLocation eventually replied. That would
        // stall `refreshPlan` mid-run, which is the one place this app can't
        // afford to hang.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.finish(id, with: .failure(LocationError.timedOut))
        }
        defer { deadline.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                requestLocation()
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: .failure(CancellationError())) }
        }
    }

    /// Resumes one waiter if it's still outstanding. Removing before
    /// resuming is what makes a double-resume impossible no matter which of
    /// the fix, the timeout, and cancellation arrives first.
    @MainActor
    private func finish(_ id: UUID, with result: Result<CLLocationCoordinate2D, Error>) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        // The timeout and cancellation paths run through here and nowhere
        // else, so this is the only place that can clear the spinner for
        // them. Without it a timed-out request leaves `isAcquiring` stuck
        // true: `PlaceSearchField` shows "Getting your location…" forever
        // (hiding the error it just set, since that's the later branch) and
        // Settings' `.disabled(isAcquiring)` locks out the one manual retry.
        if waiters.isEmpty { isAcquiring = false }
        continuation.resume(with: result)
    }

    @MainActor
    private func finishAll(with result: Result<CLLocationCoordinate2D, Error>) {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume(with: result)
        }
    }

    // MARK: CLLocationManagerDelegate
    //
    // CoreLocation delivers these on whichever queue the manager was created
    // on, which is not something this class should have to assume — every
    // callback does nothing but hop to the main actor, where all the mutable
    // state (`waiters`, the `@Observable` properties, `AppSettings`) lives.

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.isAcquiring = true
                self.manager.requestLocation()
            case .denied, .restricted:
                self.isAcquiring = false
                self.finishAll(with: .failure(LocationError.denied))
            default:
                break
            }
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        Task { @MainActor in self.receive(fix: l) }
    }

    /// CoreLocation's first delivery after `requestLocation` can be a cached
    /// fix — minutes or hours old, from across town. Stamping that as fresh
    /// made `hasFix(fresherThan:)` vouch for it for two minutes, and every
    /// "Current Location" drive ETA routed from the wrong origin, which is
    /// precisely what `currentCoordinate`'s doc promises to prevent. Reject
    /// stale or garbage-accuracy fixes and ask again while anyone is still
    /// waiting; the 10 second waiter timeout bounds the retry loop.
    @MainActor
    private func receive(fix l: CLLocation) {
        let age = Date().timeIntervalSince(l.timestamp)
        guard age <= 30, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= 200 else {
            if !waiters.isEmpty {
                manager.requestLocation()
            } else {
                isAcquiring = false
            }
            return
        }
        apply(fix: l)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // The stored coordinate still stands as a fallback — but anyone
        // *awaiting* a fix has to be told, or they sit here until the
        // timeout for a failure we already know about.
        let message = error.localizedDescription
        Task { @MainActor in
            self.isAcquiring = false
            self.finishAll(with: .failure(LocationError.failed(message)))
        }
    }

    @MainActor
    private func apply(fix l: CLLocation) {
        settings.lastLatitude = l.coordinate.latitude
        settings.lastLongitude = l.coordinate.longitude
        // The fix's own timestamp, not `Date()`: freshness bookkeeping must
        // describe when the position was measured, not when it arrived.
        settings.lastFixAt = l.timestamp
        settings.hasRealLocation = true
        isAcquiring = false
        revision &+= 1
        // Clear the old label before the new one is looked up. The
        // reverse-geocode is async and can fail outright, so leaving the
        // previous value in place means the UI shows the *last* place's
        // street name next to this fix's coordinate — get a fix at home,
        // drive to work, and "Current Location" would say "home" with
        // total confidence. Coordinates are the honest fallback.
        lastFixDescription = nil
        finishAll(with: .success(l.coordinate))
        describe(l)
    }

    /// Best-effort street/place name for a fix. Purely for display; nothing
    /// in the scheduling path waits on it.
    @MainActor
    private func describe(_ location: CLLocation) {
        geocoder.cancelGeocode()
        // Deliberately captures nothing but the resulting string — the
        // geocoder's completion is a `@Sendable` closure and this class is
        // main-actor state, so hopping back through the singleton is the
        // clean way across rather than smuggling `self` over.
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            guard let mark = placemarks?.first else { return }
            let parts = [mark.name, mark.locality].compactMap { $0 }
            let label = parts.isEmpty ? nil : parts.joined(separator: ", ")
            Task { @MainActor in LocationService.shared.lastFixDescription = label }
        }
    }
}
