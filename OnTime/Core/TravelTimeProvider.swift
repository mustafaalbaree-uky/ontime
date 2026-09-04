import Foundation
import MapKit
import CoreLocation
import Observation

protocol TravelTimeProvider: Sendable {
    func eta(from: Place, to: Place, departingAt: Date) async throws -> TimeInterval
}

enum TravelTimeSource: String, Codable, CaseIterable, Sendable {
    case live
    case cached
    case manual
}

struct ResolvedTravelTime: Sendable, Equatable {
    var duration: TimeInterval
    var source: TravelTimeSource
    var fetchedAt: Date?

    init(duration: TimeInterval, source: TravelTimeSource, fetchedAt: Date? = nil) {
        self.duration = duration
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

struct MapKitTravelProvider: TravelTimeProvider {
    init() {}

    func eta(from: Place, to: Place, departingAt: Date) async throws -> TimeInterval {
        let fromCoord = try await coordinate(for: from)
        let toCoord = try await coordinate(for: to)

        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: fromCoord))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: toCoord))
        req.transportType = .automobile
        req.departureDate = departingAt

        let directions = MKDirections(request: req)
        let response = try await directions.calculateETA()
        return response.expectedTravelTime
    }

    /// The sentinel `Place` carries no coordinate of its own — it means
    /// "wherever I am when this ETA is asked for", so it resolves against the
    /// GPS at call time and refreshes the fix if what's stored has gone
    /// stale. Every other `Place` is a fixed coordinate.
    private func coordinate(for place: Place) async throws -> CLLocationCoordinate2D {
        guard place.isCurrentLocation else {
            return CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
        }
        return try await LocationService.shared.currentCoordinate()
    }
}

struct TravelCacheKey: Hashable, Sendable {
    var originName: String
    var originLat: Double
    var originLon: Double
    var isOriginCurrent: Bool
    var destName: String
    var destLat: Double
    var destLon: Double
    var isDestCurrent: Bool

    /// `live` is the coordinate the "Current Location" sentinel resolved to
    /// for *this* lookup. It has to be part of the key: the sentinel `Place`
    /// row's own lat/long is (0, 0), so keying off it collapsed every place
    /// you have ever stood into one cache entry — leave home, lose the
    /// network mid-run, and the cache would hand back this morning's
    /// home→masjid ETA as if it were current. Bucketed to ~3 decimals
    /// (~100m) so the cache can still hit for repeated asks from one spot.
    init(from: Place, to: Place, live: CLLocationCoordinate2D? = nil) {
        self.originName = from.name
        self.isOriginCurrent = from.isCurrentLocation
        self.destName = to.name
        self.isDestCurrent = to.isCurrentLocation

        let originCoord = from.isCurrentLocation
            ? TravelCacheKey.bucket(live)
            : (lat: from.latitude, lon: from.longitude)
        self.originLat = originCoord.lat
        self.originLon = originCoord.lon

        let destCoord = to.isCurrentLocation
            ? TravelCacheKey.bucket(live)
            : (lat: to.latitude, lon: to.longitude)
        self.destLat = destCoord.lat
        self.destLon = destCoord.lon
    }

    private static func bucket(_ coord: CLLocationCoordinate2D?) -> (lat: Double, lon: Double) {
        guard let coord else { return (0, 0) }
        return ((coord.latitude * 1000).rounded() / 1000,
                (coord.longitude * 1000).rounded() / 1000)
    }
}

struct CachedETA: Sendable {
    var duration: TimeInterval
    var timestamp: Date

    init(duration: TimeInterval, timestamp: Date = Date()) {
        self.duration = duration
        self.timestamp = timestamp
    }
}

/// `@MainActor` because it is `@Observable` state SwiftUI reads, it writes
/// persisted `Block` fields bound to the main-actor `ModelContext`, and its
/// callers are all main-actor already. It used to be non-isolated, so every
/// `resolve` mutated observed dictionaries and a SwiftData model off the
/// main actor — legal under Swift 5.9's checking, intermittently racy in
/// practice, and a guaranteed wall of errors on any language-mode upgrade.
@MainActor
@Observable
final class TravelTimeService {
    static let shared = TravelTimeService()

    /// How long a resolved ETA (live from MapKit, or a cache entry) stays
    /// authoritative. Beyond this the manual chain wins again: an 8am ETA
    /// served at 10pm is wrong by the whole congestion delta, and a stale
    /// `resolvedMinutes` beating the estimate the user typed a minute ago
    /// was a real audit finding.
    static let resolvedFreshness: TimeInterval = 45 * 60

    var provider: any TravelTimeProvider
    private(set) var cache: [TravelCacheKey: CachedETA] = [:]
    /// Keyed by `Block.uuid`, not `ObjectIdentifier`: an address is
    /// reusable after deallocation, so a long session could misattribute a
    /// dead block's source or error to a fresh one, and the maps could
    /// never be safely pruned.
    private(set) var blockSources: [UUID: TravelTimeSource] = [:]
    /// Last-known-bad state per block, for `NowView`'s developer-mode panel.
    /// `resolve(block:)` clears a block's entry on success and sets it on
    /// every failure path (MapKit error, no GPS fix yet) — nothing here is
    /// swallowed silently the way it used to be.
    private(set) var blockErrors: [UUID: String] = [:]

    init(provider: any TravelTimeProvider = MapKitTravelProvider()) {
        self.provider = provider
    }

    /// nil key means "a current-location endpoint with no coordinate to
    /// anchor it": caching under the (0, 0) bucket is exactly the
    /// every-place-you-ever-stood collapse `TravelCacheKey`'s doc describes,
    /// so such lookups simply bypass the cache.
    private func cacheKey(from: Place, to: Place, live: CLLocationCoordinate2D?) -> TravelCacheKey? {
        let resolvedLive = live ?? storedCoordinate
        if resolvedLive == nil, from.isCurrentLocation || to.isCurrentLocation { return nil }
        return TravelCacheKey(from: from, to: to, live: resolvedLive)
    }

    func cachedDuration(from: Place, to: Place, live: CLLocationCoordinate2D? = nil) -> CachedETA? {
        guard let key = cacheKey(from: from, to: to, live: live) else { return nil }
        return cache[key]
    }

    func setCached(from: Place, to: Place, duration: TimeInterval, timestamp: Date = Date(), live: CLLocationCoordinate2D? = nil) {
        guard let key = cacheKey(from: from, to: to, live: live) else { return }
        cache[key] = CachedETA(duration: duration, timestamp: timestamp)
    }

    private func freshCached(_ key: TravelCacheKey?) -> CachedETA? {
        guard let key, let entry = cache[key] else { return nil }
        guard Date().timeIntervalSince(entry.timestamp) <= Self.resolvedFreshness else { return nil }
        return entry
    }

    /// The last known coordinate, or nil if the app has never had a real fix.
    private var storedCoordinate: CLLocationCoordinate2D? {
        let s = AppSettings.shared
        guard s.hasRealLocation else { return nil }
        return CLLocationCoordinate2D(latitude: s.lastLatitude, longitude: s.lastLongitude)
    }

    /// Reachable from Settings' developer section.
    func clearCache() {
        cache.removeAll()
    }

    func source(for block: Block) -> TravelTimeSource {
        blockSources[block.uuid] ?? .manual
    }

    func error(for block: Block) -> String? {
        blockErrors[block.uuid]
    }

    func resolvedAt(for block: Block) -> Date? {
        block.resolvedAt
    }

    /// A `.startAt` block ignores every other source here — it isn't a
    /// duration you set, it's a clock time you count down to. Once the
    /// block has actually started (`actualStart` set), the target resolves
    /// relative to that fixed moment rather than live `now`, which pins the
    /// duration exactly the way a `.flex` block gets pinned on entry — a
    /// moving target here would otherwise make `RunView.checkAutoAdvance`'s
    /// `elapsed >= estimate` comparison fire around the *midpoint* between
    /// start and target instead of at the target, since both sides of that
    /// comparison would be sliding at once.
    func manualEstimateMinutes(for block: Block, now: Date = Date()) -> Int {
        if block.kind == .startAt, let hour = block.targetHour, let minute = block.targetMinute {
            let reference = block.actualStart ?? now
            let target = DeadlineResolver.resolve(hour: hour, minute: minute, now: reference, calendar: .current)
            return max(0, Int((target.timeIntervalSince(reference) / 60).rounded(.up)))
        }
        // A drive block's `estimateOverrideMinutes` is always set at save
        // time by `QuickBlockEditorSheet` — the duration
        // scrubber writes it whether or not the user touched it — so
        // checking it first meant a live ETA from `resolve(block:)` could
        // never win: the moment a run started, every drive step's schedule
        // silently fell back to whatever the scrubber said (often the 10
        // min default) even though `block.resolvedMinutes` held a real,
        // just-fetched ETA. The scrubber's own UI copy ("Used until a live
        // ETA comes in") already promises this precedence.
        //
        // But only while the ETA is *fresh*. `resolvedMinutes` used to win
        // forever (it persisted with no timestamp), so an ETA fetched days
        // ago at a different time of day beat an estimate the user typed a
        // minute ago. Fresh live number first; past `resolvedFreshness` the
        // manual chain takes over, with the stale resolved value demoted to
        // its documented last-resort slot near the end.
        if block.kind == .drive, block.resolvedMinutes > 0,
           let at = block.resolvedAt, now.timeIntervalSince(at) <= Self.resolvedFreshness {
            return block.resolvedMinutes
        }
        if let override = block.estimateOverrideMinutes {
            return override
        }
        // The *learned* duration, not the bare manual prior. `Estimator`
        // already blends recorded `DurationSample`s toward that prior
        // (weighted `n / (n + 3)`, 30-day half-life), and every screen that
        // displays a template shows the blended number — but this function
        // is what actually feeds `SolverInput`, and it used to read
        // `template.manualEstimateMinutes` directly. So the app showed you a
        // learned estimate everywhere while quietly scheduling against the
        // guess you typed the first time, no matter how many times you'd
        // since run the step. With no samples `estimate` returns the prior
        // exactly, so this is a strict improvement, never a regression.
        if let template = block.template {
            let observations = template.samples.map {
                DurationObservation(minutes: $0.minutes, recordedAt: $0.recordedAt)
            }
            return Estimator.estimate(
                observations: observations,
                prior: template.manualEstimateMinutes,
                confidence: AppSettings.shared.confidenceIsSafe ? .safe : .typical
            )
        }
        if block.resolvedMinutes > 0 {
            return block.resolvedMinutes
        }
        return 10
    }

    @discardableResult
    func resolveETA(from origin: Place, to destination: Place, manualEstimate: Int, departingAt: Date) async -> ResolvedTravelTime {
        let live = (origin.isCurrentLocation || destination.isCurrentLocation)
            ? try? await LocationService.shared.currentCoordinate()
            : nil
        let key = cacheKey(from: origin, to: destination, live: live)
        do {
            let eta = try await provider.eta(from: origin, to: destination, departingAt: departingAt)
            let now = Date()
            if let key { cache[key] = CachedETA(duration: eta, timestamp: now) }
            return ResolvedTravelTime(duration: eta, source: .live, fetchedAt: now)
        } catch {
            if let cached = freshCached(key) {
                return ResolvedTravelTime(duration: cached.duration, source: .cached, fetchedAt: cached.timestamp)
            }
            let manualSec = TimeInterval(manualEstimate * 60)
            return ResolvedTravelTime(duration: manualSec, source: .manual, fetchedAt: nil)
        }
    }

    @discardableResult
    func resolve(block: Block, departingAt: Date = Date()) async -> ResolvedTravelTime {
        let id = block.uuid
        let manual = manualEstimateMinutes(for: block)

        // "Override Route — Use Estimate": skip MapKit and the GPS fix
        // entirely, same fallback path as a missing origin/destination
        // below, but chosen deliberately rather than because the route
        // can't be resolved.
        if block.kind == .drive, block.useManualEstimateOnly {
            let res = ResolvedTravelTime(duration: TimeInterval(manual * 60), source: .manual, fetchedAt: nil)
            block.resolvedMinutes = manual
            block.resolvedAt = Date()
            blockSources[id] = .manual
            blockErrors[id] = nil
            return res
        }

        guard block.kind == .drive,
              let origin = block.originPlace,
              let dest = block.destinationPlace else {
            let res = ResolvedTravelTime(duration: TimeInterval(manual * 60), source: .manual, fetchedAt: nil)
            block.resolvedMinutes = manual
            block.resolvedAt = Date()
            blockSources[id] = .manual
            blockErrors[id] = block.kind == .drive ? "Missing origin or destination" : nil
            return res
        }

        // A "Current Location" origin/destination has no coordinate of its
        // own, so ask the GPS for one now rather than routing from whatever
        // stale value happened to be lying around (or from (0, 0), which
        // asks MapKit for directions out of the Gulf of Guinea and yields a
        // garbage multi-day ETA). If the fix can't be had — access denied,
        // no signal — fall back to the manual estimate and say why.
        var live: CLLocationCoordinate2D?
        if origin.isCurrentLocation || dest.isCurrentLocation {
            do {
                live = try await LocationService.shared.currentCoordinate()
            } catch {
                let res = ResolvedTravelTime(duration: TimeInterval(manual * 60), source: .manual, fetchedAt: nil)
                block.resolvedMinutes = manual
                block.resolvedAt = Date()
                blockSources[id] = .manual
                blockErrors[id] = error.localizedDescription
                return res
            }
        }

        let key = cacheKey(from: origin, to: dest, live: live)
        do {
            let eta = try await provider.eta(from: origin, to: dest, departingAt: departingAt)
            let now = Date()
            if let key { cache[key] = CachedETA(duration: eta, timestamp: now) }
            block.resolvedMinutes = max(1, Int((eta / 60.0).rounded()))
            block.resolvedAt = now
            blockSources[id] = .live
            blockErrors[id] = nil
            return ResolvedTravelTime(duration: eta, source: .live, fetchedAt: now)
        } catch {
            blockErrors[id] = error.localizedDescription
            if let cached = freshCached(key) {
                block.resolvedMinutes = max(1, Int((cached.duration / 60.0).rounded()))
                block.resolvedAt = cached.timestamp
                blockSources[id] = .cached
                return ResolvedTravelTime(duration: cached.duration, source: .cached, fetchedAt: cached.timestamp)
            }
            block.resolvedMinutes = manual
            block.resolvedAt = Date()
            blockSources[id] = .manual
            return ResolvedTravelTime(duration: TimeInterval(manual * 60), source: .manual, fetchedAt: nil)
        }
    }

    func refreshPlan(_ plan: Plan, departingAt: Date = Date()) async {
        for block in plan.orderedBlocks where block.kind == .drive {
            await resolve(block: block, departingAt: departingAt)
        }
    }
}
