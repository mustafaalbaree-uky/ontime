import Foundation
import Observation

/// Preferences.
///
/// Every property here is a *stored* property with a `didSet` that persists.
/// That matters: `@Observable` only tracks stored properties, so a computed
/// property backed by UserDefaults reads and writes correctly but never tells
/// SwiftUI anything changed — see shadiliya's `AppSettings` for the theme
/// picker bug that came from getting this wrong.
@Observable
final class AppSettings {

    static let shared = AppSettings()
    @ObservationIgnored private let d = UserDefaults.standard
    /// Suppresses writes while `init` is populating from disk.
    @ObservationIgnored private var loading = true

    /// Whether estimates should lean on the conservative (p80) side of a
    /// template's duration history rather than the median (p50).
    var confidenceIsSafe: Bool = true { didSet { save("confidenceIsSafe", confidenceIsSafe) } }

    var lastLatitude: Double = 0 { didSet { save("lastLatitude", lastLatitude) } }
    var lastLongitude: Double = 0 { didSet { save("lastLongitude", lastLongitude) } }
    var hasRealLocation: Bool = false { didSet { save("hasRealLocation", hasRealLocation) } }
    /// When `lastLatitude`/`lastLongitude` were last actually measured.
    /// `hasRealLocation` alone stays true forever once set, so without this a
    /// coordinate from days ago looks exactly like a coordinate from ten
    /// seconds ago — and a drive block would happily route from it.
    var lastFixAt: Date? = nil { didSet { save("lastFixAt", lastFixAt) } }

    var defaultLeadWarningMinutes: Int = 5 { didSet { save("defaultLeadWarningMinutes", defaultLeadWarningMinutes) } }

    /// Default for whether a `Run` advances to the next step on its own once
    /// the current step's estimated duration has elapsed, vs. waiting for a
    /// manual "Next Step" tap. On by default as of 2026-08 — a step sitting
    /// unadvanced past its estimate used to read as a bug ("overdue," count
    /// up on the Live Activity with no explanation) precisely because manual
    /// mode was the silent default nobody had opted into. Manual tapping is
    /// still how `RunView` measures a step's *actual* duration for
    /// `Estimator`, so turning auto-advance off (per-run toggle, or a step
    /// pinned via `Block.isOpenEnded`) is still the way to get that
    /// measurement back. `RunView` seeds its per-run toggle from this but can
    /// flip it locally without changing the app-wide default.
    var autoAdvanceEnabled: Bool = true { didSet { save("autoAdvanceEnabled", autoAdvanceEnabled) } }

    /// Last-picked Final Time on `NowView`, as a bare time-of-day — resolved
    /// to the next occurrence of that clock time on every launch via
    /// `DeadlineResolver`, not stored as an absolute `Date` (which would be
    /// in the past the moment the app reopens).
    var quickDeadlineHour: Int = 9 { didSet { save("quickDeadlineHour", quickDeadlineHour) } }
    var quickDeadlineMinute: Int = 0 { didSet { save("quickDeadlineMinute", quickDeadlineMinute) } }

    /// Surfaces a debug panel on `NowView` — live location/travel-time
    /// internals that are otherwise invisible (GPS fix state, which tier
    /// answered each drive block's ETA, the last MapKit error). Off by
    /// default; nothing here is meant for the shipped experience.
    var developerModeEnabled: Bool = false { didSet { save("developerModeEnabled", developerModeEnabled) } }

    private func save(_ key: String, _ value: Any?) {
        guard !loading else { return }
        d.set(value, forKey: key)
    }

    private init() {
        confidenceIsSafe = d.object(forKey: "confidenceIsSafe") == nil
            ? true : d.bool(forKey: "confidenceIsSafe")
        if d.object(forKey: "lastLatitude") != nil { lastLatitude = d.double(forKey: "lastLatitude") }
        if d.object(forKey: "lastLongitude") != nil { lastLongitude = d.double(forKey: "lastLongitude") }
        hasRealLocation = d.bool(forKey: "hasRealLocation")
        lastFixAt = d.object(forKey: "lastFixAt") as? Date
        defaultLeadWarningMinutes = d.object(forKey: "defaultLeadWarningMinutes") == nil
            ? 5 : d.integer(forKey: "defaultLeadWarningMinutes")
        autoAdvanceEnabled = d.object(forKey: "autoAdvanceEnabled") == nil
            ? true : d.bool(forKey: "autoAdvanceEnabled")
        quickDeadlineHour = d.object(forKey: "quickDeadlineHour") == nil ? 9 : d.integer(forKey: "quickDeadlineHour")
        quickDeadlineMinute = d.object(forKey: "quickDeadlineMinute") == nil ? 0 : d.integer(forKey: "quickDeadlineMinute")
        developerModeEnabled = d.bool(forKey: "developerModeEnabled")

        loading = false
    }
}
