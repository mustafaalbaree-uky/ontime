import Foundation
import CoreLocation
import Testing
@testable import OnTime

struct StubTravelTimeProvider: TravelTimeProvider {
    var result: Result<TimeInterval, Error>

    func eta(from: Place, to: Place, departingAt: Date) async throws -> TimeInterval {
        try result.get()
    }
}

enum StubError: Error {
    case networkFailure
}

@MainActor
struct TravelTimeTests {
    @Test func liveProviderUpdatesCacheAndReturnsLiveSource() async throws {
        let provider = StubTravelTimeProvider(result: .success(18 * 60))
        let service = TravelTimeService(provider: provider)
        let home = Place(name: "Home", latitude: 37.77, longitude: -122.41)
        let work = Place(name: "Work", latitude: 37.78, longitude: -122.40)

        let result = await service.resolveETA(from: home, to: work, manualEstimate: 12, departingAt: Date())
        #expect(result.source == .live)
        #expect(result.duration == TimeInterval(18 * 60))
        #expect(try #require(service.cachedDuration(from: home, to: work)?.duration) == TimeInterval(18 * 60))
    }

    @Test func failedProviderFallsBackToCacheWhenAvailable() async {
        let successProvider = StubTravelTimeProvider(result: .success(20 * 60))
        let service = TravelTimeService(provider: successProvider)
        let home = Place(name: "Home", latitude: 37.77, longitude: -122.41)
        let work = Place(name: "Work", latitude: 37.78, longitude: -122.40)

        // Seed cache
        _ = await service.resolveETA(from: home, to: work, manualEstimate: 10, departingAt: Date())

        // Switch to failing provider
        service.provider = StubTravelTimeProvider(result: .failure(StubError.networkFailure))

        let fallbackResult = await service.resolveETA(from: home, to: work, manualEstimate: 10, departingAt: Date())
        #expect(fallbackResult.source == .cached)
        #expect(fallbackResult.duration == TimeInterval(20 * 60))
    }

    @Test func failedProviderFallsBackToManualEstimateWhenNoCache() async {
        let failingProvider = StubTravelTimeProvider(result: .failure(StubError.networkFailure))
        let service = TravelTimeService(provider: failingProvider)
        let home = Place(name: "Home", latitude: 37.77, longitude: -122.41)
        let work = Place(name: "Work", latitude: 37.78, longitude: -122.40)

        let result = await service.resolveETA(from: home, to: work, manualEstimate: 15, departingAt: Date())
        #expect(result.source == .manual)
        #expect(result.duration == TimeInterval(15 * 60))
    }

    /// The "Current Location" sentinel's own lat/long are (0, 0), so keying
    /// the cache off the `Place` row put every place you have ever stood
    /// into a single entry: an ETA cached at home came back as `.cached`
    /// after you had driven across town. The key has to carry the coordinate
    /// the sentinel actually resolved to.
    @Test func currentLocationCacheDoesNotCollideAcrossDifferentFixes() {
        let service = TravelTimeService(provider: StubTravelTimeProvider(result: .success(0)))
        let here = Place(name: "Current Location", isCurrentLocation: true)
        let masjid = Place(name: "Masjid", latitude: 38.04, longitude: -84.50)

        let atHome = CLLocationCoordinate2D(latitude: 38.00, longitude: -84.51)
        let acrossTown = CLLocationCoordinate2D(latitude: 38.20, longitude: -84.30)

        service.setCached(from: here, to: masjid, duration: 25 * 60, live: atHome)

        #expect(service.cachedDuration(from: here, to: masjid, live: atHome)?.duration == TimeInterval(25 * 60))
        #expect(service.cachedDuration(from: here, to: masjid, live: acrossTown) == nil)
    }

    /// …but it still has to *hit* for repeated asks from one spot, or the
    /// cache tier stops existing for current-location drives. GPS jitter of
    /// a few meters must land in the same ~100m bucket.
    @Test func currentLocationCacheHitsDespiteSmallGPSJitter() {
        let service = TravelTimeService(provider: StubTravelTimeProvider(result: .success(0)))
        let here = Place(name: "Current Location", isCurrentLocation: true)
        let masjid = Place(name: "Masjid", latitude: 38.04, longitude: -84.50)

        let fix = CLLocationCoordinate2D(latitude: 38.0001, longitude: -84.5001)
        let jittered = CLLocationCoordinate2D(latitude: 38.0002, longitude: -84.5002)

        service.setCached(from: here, to: masjid, duration: 25 * 60, live: fix)
        #expect(service.cachedDuration(from: here, to: masjid, live: jittered)?.duration == TimeInterval(25 * 60))
    }

    /// A cache entry has an age now: an ETA cached this morning must not be
    /// served as `.cached` tonight — the schedule built on it would be
    /// wrong by the whole congestion delta.
    @Test func staleCacheEntriesFallThroughToManual() async {
        let service = TravelTimeService(provider: StubTravelTimeProvider(result: .failure(StubError.networkFailure)))
        let home = Place(name: "Home", latitude: 37.77, longitude: -122.41)
        let work = Place(name: "Work", latitude: 37.78, longitude: -122.40)

        service.setCached(from: home, to: work, duration: 25 * 60,
                          timestamp: Date().addingTimeInterval(-2 * 60 * 60))

        let result = await service.resolveETA(from: home, to: work, manualEstimate: 12, departingAt: Date())
        #expect(result.source == .manual)
        #expect(result.duration == TimeInterval(12 * 60))
    }

    // MARK: - The manual estimate precedence chain
    //
    // `manualEstimateMinutes` is the sole feeder of SolverInput durations,
    // and its doc comments memorialize two real shipped bugs; this is the
    // first test of its ordering. The chain: fresh resolved ETA (drive),
    // then override, then learned template estimate, then stale resolved,
    // then the 10 minute default.

    @Test func freshResolvedETABeatsTheOverrideForADriveBlock() {
        let service = TravelTimeService(provider: StubTravelTimeProvider(result: .success(0)))
        let now = Date()
        let block = Block(order: 0, name: "Drive", kind: .drive, estimateOverrideMinutes: 9, resolvedMinutes: 22)
        block.resolvedAt = now.addingTimeInterval(-5 * 60)

        #expect(service.manualEstimateMinutes(for: block, now: now) == 22)
    }

    @Test func staleResolvedETALosesToTheOverride() {
        let service = TravelTimeService(provider: StubTravelTimeProvider(result: .success(0)))
        let now = Date()
        let block = Block(order: 0, name: "Drive", kind: .drive, estimateOverrideMinutes: 9, resolvedMinutes: 22)
        block.resolvedAt = now.addingTimeInterval(-2 * 60 * 60)

        #expect(service.manualEstimateMinutes(for: block, now: now) == 9)
    }

    @Test func overrideBeatsTheTemplateEstimate() {
        let service = TravelTimeService(provider: StubTravelTimeProvider(result: .success(0)))
        let template = TaskTemplate(name: "Shower", manualEstimateMinutes: 12)
        let block = Block(order: 0, name: "Shower", kind: .fixed, template: template, estimateOverrideMinutes: 8)

        #expect(service.manualEstimateMinutes(for: block) == 8)
    }

    @Test func templateEstimateBeatsStaleResolvedMinutes() {
        let service = TravelTimeService(provider: StubTravelTimeProvider(result: .success(0)))
        let template = TaskTemplate(name: "Drive", kind: .drive, manualEstimateMinutes: 12)
        let block = Block(order: 0, name: "Drive", kind: .drive, template: template, resolvedMinutes: 22)
        block.resolvedAt = Date().addingTimeInterval(-3 * 60 * 60)

        #expect(service.manualEstimateMinutes(for: block) == 12)
    }

    @Test func staleResolvedIsTheLastResortBeforeTheDefault() {
        let service = TravelTimeService(provider: StubTravelTimeProvider(result: .success(0)))
        let stale = Block(order: 0, name: "Drive", kind: .drive, resolvedMinutes: 22)
        stale.resolvedAt = Date().addingTimeInterval(-3 * 60 * 60)
        #expect(service.manualEstimateMinutes(for: stale) == 22)

        let bare = Block(order: 0, name: "Step", kind: .fixed)
        #expect(service.manualEstimateMinutes(for: bare) == 10)
    }
}
