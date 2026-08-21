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
}
