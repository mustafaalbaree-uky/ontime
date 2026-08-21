import Foundation

/// Which quantile of the (weighted) observation distribution to report.
enum Confidence {
    /// p50 — the typical case.
    case typical
    /// p80 — biased late so "don't make me late" holds most of the time.
    case safe
}

struct DurationObservation {
    var minutes: Int
    var recordedAt: Date
}

/// Learns a duration estimate from logged observations, blended toward a
/// manual prior while the sample is small.
enum Estimator {
    /// Observations lose half their weight every 30 days. Chosen so a habit
    /// that changed a month ago (new commute, new routine) dominates within
    /// a couple of half-lives, while a single old outlier doesn't linger
    /// forever — short enough to track real drift, long enough that one
    /// unusual day doesn't swing the estimate.
    private static let halfLifeDays: Double = 30

    /// Blend weight toward the data: n / (n + 3). At n=3 the data and the
    /// prior are weighted equally; a lone observation (n=1) still leans
    /// mostly on the prior (1/4) rather than betting the estimate on one
    /// data point, and the weight approaches 1 smoothly as observations
    /// accumulate. 3 is the smallest pseudo-count that keeps a single
    /// sample from dominating while still letting a handful of samples
    /// mean something.
    private static let priorPseudoCount: Double = 3

    static func estimate(observations: [DurationObservation],
                          prior: Int,
                          confidence: Confidence,
                          now: Date = Date()) -> Int {
        let n = observations.count
        guard n > 0 else { return prior }

        let q: Double
        switch confidence {
        case .typical: q = 0.5
        case .safe: q = 0.8
        }

        let weighted: [(value: Double, weight: Double)] = observations.map { obs in
            let ageDays = max(0, now.timeIntervalSince(obs.recordedAt)) / 86400
            let weight = pow(0.5, ageDays / halfLifeDays)
            return (Double(obs.minutes), weight)
        }

        let quantileValue = weightedQuantile(weighted, q: q)

        let wData = Double(n) / (Double(n) + priorPseudoCount)
        let blended = wData * quantileValue + (1 - wData) * Double(prior)
        return Int(blended.rounded())
    }

    /// Sorts by value, accumulates weight, and returns the value at which
    /// cumulative weight first reaches `q` of the total — i.e. the weighted
    /// quantile. Already robust to outliers by construction (an extreme
    /// value just sits at one end of the sort and only contributes its own
    /// weight), so no separate trimming/winsorizing step is applied.
    private static func weightedQuantile(_ items: [(value: Double, weight: Double)], q: Double) -> Double {
        let sorted = items.sorted { $0.value < $1.value }
        let totalWeight = sorted.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            // All weights collapsed to ~0 (e.g. extremely old observations).
            // Fall back to the plain median of values so we still return
            // something sane rather than dividing by zero.
            let values = sorted.map(\.value)
            return values[values.count / 2]
        }

        let target = q * totalWeight
        var cumulative: Double = 0
        for item in sorted {
            cumulative += item.weight
            if cumulative >= target {
                return item.value
            }
        }
        return sorted.last?.value ?? 0
    }
}
