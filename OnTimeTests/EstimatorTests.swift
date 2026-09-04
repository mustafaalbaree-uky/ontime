import Foundation
import Testing
@testable import OnTime

struct EstimatorTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86400)
    }

    // MARK: 12. n = 0 returns prior exactly.

    @Test func zeroObservationsReturnsPriorExactly() {
        let result = Estimator.estimate(observations: [], prior: 15, confidence: .typical, now: now)
        #expect(result == 15)
    }

    // MARK: 13. Converges toward the observations as n grows.

    @Test func convergesTowardObservationsAsNGrows() {
        // All observations equal 20, recorded now (full weight), so the
        // weighted quantile is exactly 20 regardless of n or confidence —
        // isolating the blend-toward-prior behavior as n grows.
        let prior = 10
        func estimate(n: Int) -> Int {
            let obs = (0..<n).map { _ in DurationObservation(minutes: 20, recordedAt: now) }
            return Estimator.estimate(observations: obs, prior: prior, confidence: .typical, now: now)
        }

        let e1 = estimate(n: 1)
        let e3 = estimate(n: 3)
        let e10 = estimate(n: 10)
        let e50 = estimate(n: 50)

        // n=1: wData=1/4 -> 0.25*20+0.75*10=12.5 -> 13
        #expect(e1 == 13)
        // n=3: wData=3/6=0.5 -> 0.5*20+0.5*10=15
        #expect(e3 == 15)
        // Monotonically approaching the observed value as n grows.
        #expect(e1 < e3)
        #expect(e3 < e10)
        #expect(e10 < e50)
        #expect(e50 <= 20)
        #expect(20 - e50 <= 2)
    }

    // MARK: 14. Recency: a cluster of recent values beats an old cluster of different values.

    @Test func recentClusterDominatesOldCluster() {
        let old = (0..<5).map { _ in DurationObservation(minutes: 10, recordedAt: daysAgo(180)) }
        let recent = (0..<5).map { _ in DurationObservation(minutes: 30, recordedAt: now) }
        let result = Estimator.estimate(observations: old + recent, prior: 20, confidence: .typical, now: now)

        // 180 days ago is 6 half-lives back (weight 1/64 each), so the
        // recent cluster carries ~98% of the weight — result should sit
        // much closer to 30 than to 10.
        #expect(abs(result - 30) < abs(result - 10))
        #expect(result > 20)
    }

    // MARK: 15. safe (p80) >= typical (p50) on a spread sample.

    @Test func safeIsAtLeastTypicalOnSpreadSample() {
        let observations = [10, 15, 20, 25, 30].map { DurationObservation(minutes: $0, recordedAt: now) }
        let typical = Estimator.estimate(observations: observations, prior: 20, confidence: .typical, now: now)
        let safe = Estimator.estimate(observations: observations, prior: 20, confidence: .safe, now: now)
        #expect(safe >= typical)
        // p50 of [10,15,20,25,30] is 20, p80 is 25 — with equal prior=20,
        // safe should come out strictly higher here.
        #expect(safe > typical)
    }

    // MARK: 14b. A purely stale history cedes authority back to the prior.
    // The blend used to weight by raw count, so ten samples from six months
    // ago kept ~77% authority exactly as if recorded today; with the
    // decayed effective weight they carry almost none.

    @Test func staleClusterCedesToThePrior() {
        let stale = (0..<10).map { _ in DurationObservation(minutes: 60, recordedAt: daysAgo(180)) }
        let result = Estimator.estimate(observations: stale, prior: 10, confidence: .typical, now: now)

        // Ten samples at 6 half-lives carry a total weight of ~0.16, so
        // wData is ~5% and the estimate sits near the prior, not near 60.
        #expect(result <= 15)
        #expect(result >= 10)
    }

    // MARK: 14c. Fresh samples still carry full weight — the effective
    // count equals the raw count when nothing has decayed, so this pins
    // that the stale-data fix did not change fresh behavior.

    @Test func freshSamplesKeepFullBlendWeight() {
        let fresh = (0..<10).map { _ in DurationObservation(minutes: 60, recordedAt: now) }
        let result = Estimator.estimate(observations: fresh, prior: 10, confidence: .typical, now: now)
        // wData = 10/13 -> 0.769*60 + 0.231*10 = 48.5 -> 48 or 49.
        #expect(result >= 45)
    }

    // MARK: 16. A single observation doesn't swing the estimate wildly off prior.

    @Test func singleObservationDoesNotSwingWildly() {
        let prior = 10
        let observations = [DurationObservation(minutes: 60, recordedAt: now)]
        let result = Estimator.estimate(observations: observations, prior: prior, confidence: .typical, now: now)

        // wData = 1/4 -> 0.25*60 + 0.75*10 = 22.5 -> 23. Moved toward the
        // observation, but nowhere near it.
        #expect(result == 23)
        #expect(result < 30)
        #expect(result > prior)
    }
}
