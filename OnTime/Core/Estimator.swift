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

    /// Blend weight toward the data: W / (W + 3), where W is the *decayed*
    /// total weight of the observations, not their raw count. Three fresh
    /// samples weigh the data and the prior equally; a lone fresh
    /// observation still leans mostly on the prior (1/4). Using the raw
    /// count here was a real bug: ten samples from six months ago kept 77%
    /// authority over the prior exactly as if they were recorded today, so
    /// "old outliers fade" was only true relative to newer samples, never
    /// relative to the typed prior. With decayed weight, a dormant step's
    /// estimate drifts back toward the prior as its history ages out.
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

        let effectiveN = weighted.reduce(0) { $0 + $1.weight }
        let wData = effectiveN / (effectiveN + priorPseudoCount)
        let blended = wData * quantileValue + (1 - wData) * Double(prior)
        return Int(blended.rounded())
    }

    /// Weighted quantile, interpolated between adjacent order statistics
    /// (each value sits at the midpoint of its own cumulative weight span).
    /// The step version this replaces snapped to the first value whose
    /// cumulative weight crossed the target, so on a small sample one added
    /// observation could move the reported p80 by the full gap between
    /// neighbors. Robust to outliers by construction (an extreme value just
    /// sits at one end of the sort and only contributes its own weight), so
    /// no separate trimming/winsorizing step is applied.
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
        guard sorted.count > 1 else { return sorted[0].value }

        var cumulative: Double = 0
        var points: [(p: Double, value: Double)] = []
        points.reserveCapacity(sorted.count)
        for item in sorted {
            points.append((p: (cumulative + item.weight / 2) / totalWeight, value: item.value))
            cumulative += item.weight
        }

        if q <= points[0].p { return points[0].value }
        guard let last = points.last, q < last.p else { return points.last?.value ?? 0 }
        for i in 1..<points.count where q <= points[i].p {
            let lo = points[i - 1]
            let hi = points[i]
            let t = (q - lo.p) / (hi.p - lo.p)
            return lo.value + t * (hi.value - lo.value)
        }
        return last.value
    }
}
