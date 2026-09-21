import Foundation
import Observation

/// Preferences.
///
/// Every property here is a *stored* property with a `didSet` that persists.
/// That matters: `@Observable` only tracks stored properties, so a computed
/// property backed by UserDefaults reads and writes correctly but never tells
/// SwiftUI anything changed — see shadiliya's `AppSettings` for the theme
/// picker bug that came from getting this wrong.
///
/// Each setting has exactly one key (the `Key` enum) and one default (the
/// property's declared value, which `init` reads back through the typed
/// loaders). The old shape spelled every key and every default twice, as
/// free literals nothing checked for agreement — a mismatch split reads and
/// writes across two keys silently. Integer loads are clamped to the same
/// ranges the Settings UI enforces, so an out-of-range persisted value (a
/// negative safety percent would *shrink* walk estimates) cannot leak in
/// from disk.
@Observable
final class AppSettings {

    static let shared = AppSettings(defaults: .standard)
    @ObservationIgnored private let d: UserDefaults
    /// Suppresses writes while `init` is populating from disk.
    @ObservationIgnored private var loading = true

    private enum Key: String {
        case confidenceIsSafe
        case lastLatitude
        case lastLongitude
        case hasRealLocation
        case lastFixAt
        case walkSafetyPercent
        case walkHeadsUpMinutes
        case defaultLeadWarningMinutes
        case autoAdvanceEnabled
        case quickDeadlineHour
        case quickDeadlineMinute
        case developerModeEnabled
        case notificationSoundEnabled
        case leadWarningsEnabled
        case sequenceNewestFirst
        case startAlarmRoutineIds
    }

    /// Whether estimates should lean on the conservative (p80) side of a
    /// template's duration history rather than the median (p50).
    var confidenceIsSafe: Bool = true { didSet { save(.confidenceIsSafe, confidenceIsSafe) } }

    /// The routines (by `uuid`) that ring a real alarm when they have to
    /// start. See `StartAlarms`. Kept here rather than as a property on
    /// `ScheduledRoutine` because there is no schema migration: a new model
    /// field risks rebuilding the store, and a wiped routine list is a far
    /// worse morning than a setting living in UserDefaults.
    var startAlarmRoutineIds: [String] = [] { didSet { save(.startAlarmRoutineIds, startAlarmRoutineIds) } }

    func wantsStartAlarm(_ routine: UUID) -> Bool {
        startAlarmRoutineIds.contains(routine.uuidString)
    }

    func setWantsStartAlarm(_ wants: Bool, for routine: UUID) {
        var ids = startAlarmRoutineIds.filter { $0 != routine.uuidString }
        if wants { ids.append(routine.uuidString) }
        startAlarmRoutineIds = ids
    }

    var lastLatitude: Double = 0 { didSet { save(.lastLatitude, lastLatitude) } }
    var lastLongitude: Double = 0 { didSet { save(.lastLongitude, lastLongitude) } }
    var hasRealLocation: Bool = false { didSet { save(.hasRealLocation, hasRealLocation) } }
    /// When `lastLatitude`/`lastLongitude` were last actually measured.
    /// `hasRealLocation` alone stays true forever once set, so without this a
    /// coordinate from days ago looks exactly like a coordinate from ten
    /// seconds ago — and a drive block would happily route from it.
    var lastFixAt: Date? = nil { didSet { save(.lastFixAt, lastFixAt) } }

    /// Percent padding added to a walk block's estimated time home, as a
    /// whole number. The estimate itself is unbiased, so this is not a
    /// correction — it is the price of an asymmetry: turning around a
    /// couple of minutes early costs nothing, and turning around two
    /// minutes late costs the thing the deadline was set for. 15% of a
    /// twenty minute walk home is three minutes.
    var walkSafetyPercent: Int = 15 { didSet { save(.walkSafetyPercent, walkSafetyPercent) } }

    /// `walkSafetyPercent` as the fraction `WalkMath.returnEstimate` wants.
    /// Computed, and therefore deliberately *not* a settings property in
    /// its own right — see the note at the top of this file about
    /// `@Observable` and stored properties. Reading it observes
    /// `walkSafetyPercent`, which is the stored one, so SwiftUI still
    /// re-renders correctly.
    var walkSafetyFraction: Double { Double(walkSafetyPercent) / 100.0 }

    /// How long before the turnaround moment the first, softer walk alert
    /// fires. The one at zero is an instruction; this one is a warning, and
    /// it is the one that actually changes a decision, because it arrives
    /// while there is still a choice about which way to go.
    var walkHeadsUpMinutes: Int = 10 { didSet { save(.walkHeadsUpMinutes, walkHeadsUpMinutes) } }

    var defaultLeadWarningMinutes: Int = 5 { didSet { save(.defaultLeadWarningMinutes, defaultLeadWarningMinutes) } }

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
    var autoAdvanceEnabled: Bool = true { didSet { save(.autoAdvanceEnabled, autoAdvanceEnabled) } }

    /// Last-picked Final Time on `NowView`, as a bare time-of-day — resolved
    /// to the next occurrence of that clock time on every launch via
    /// `DeadlineResolver`, not stored as an absolute `Date` (which would be
    /// in the past the moment the app reopens).
    var quickDeadlineHour: Int = 9 { didSet { save(.quickDeadlineHour, quickDeadlineHour) } }
    var quickDeadlineMinute: Int = 0 { didSet { save(.quickDeadlineMinute, quickDeadlineMinute) } }

    /// Whether any notification this app posts carries a sound. Off leaves
    /// every banner and every Notification Center entry exactly as it was,
    /// silently — the setting for wanting to be told without being
    /// interrupted. The app never sounds in the foreground regardless; see
    /// `Notifications.userNotificationCenter(_:willPresent:)`.
    var notificationSoundEnabled: Bool = true { didSet { save(.notificationSoundEnabled, notificationSoundEnabled) } }

    /// Whether each step also gets a warning `defaultLeadWarningMinutes`
    /// before its target, on top of the alert at the target itself.
    ///
    /// **Off by default**, which is a change: every step used to fire twice,
    /// both with sound, so a five step routine made ten noises to describe a
    /// span the Live Activity was already counting down on the Lock Screen.
    /// The lead warning is the half that tells you something you can already
    /// see. Turning it back on now gets you a silent, `.passive` entry
    /// rather than a second banner.
    var leadWarningsEnabled: Bool = false { didSet { save(.leadWarningsEnabled, leadWarningsEnabled) } }

    /// Which end of a sequence shows at the top of the list.
    ///
    /// The app's original answer was "last step first", on the reasoning
    /// that Final Time sits at the top of the screen so the step running
    /// just before it belongs directly underneath. That is a real argument
    /// and it is also completely backwards if you think forwards, which is
    /// what building a sequence feels like. It is a preference, not a fact,
    /// so it is a switch: this flips every list of steps in the app at once,
    /// and nothing about the stored `order` changes. `Sequence Editor`'s
    /// Reverse button is the other thing, and it does change the data.
    var sequenceNewestFirst: Bool = false { didSet { save(.sequenceNewestFirst, sequenceNewestFirst) } }

    /// Surfaces a debug panel on `NowView` — live location/travel-time
    /// internals that are otherwise invisible (GPS fix state, which tier
    /// answered each drive block's ETA, the last MapKit error). Off by
    /// default; nothing here is meant for the shipped experience.
    var developerModeEnabled: Bool = false { didSet { save(.developerModeEnabled, developerModeEnabled) } }

    private func save(_ key: Key, _ value: Any?) {
        guard !loading else { return }
        d.set(value, forKey: key.rawValue)
    }

    private func bool(_ key: Key, default def: Bool) -> Bool {
        d.object(forKey: key.rawValue) == nil ? def : d.bool(forKey: key.rawValue)
    }

    private func int(_ key: Key, default def: Int, in range: ClosedRange<Int>) -> Int {
        guard d.object(forKey: key.rawValue) != nil else { return def }
        return min(max(d.integer(forKey: key.rawValue), range.lowerBound), range.upperBound)
    }

    private func double(_ key: Key, default def: Double) -> Double {
        d.object(forKey: key.rawValue) == nil ? def : d.double(forKey: key.rawValue)
    }

    /// Internal (not private) so tests can point an instance at their own
    /// suite instead of polluting `.standard`. The app only ever uses
    /// `shared`.
    init(defaults: UserDefaults) {
        d = defaults
        // Property declaration values above are the single source of each
        // default: every load below hands the current (declared) value back
        // as the fallback.
        confidenceIsSafe = bool(.confidenceIsSafe, default: confidenceIsSafe)
        lastLatitude = double(.lastLatitude, default: lastLatitude)
        lastLongitude = double(.lastLongitude, default: lastLongitude)
        hasRealLocation = bool(.hasRealLocation, default: hasRealLocation)
        lastFixAt = d.object(forKey: Key.lastFixAt.rawValue) as? Date
        walkSafetyPercent = int(.walkSafetyPercent, default: walkSafetyPercent, in: 0...50)
        walkHeadsUpMinutes = int(.walkHeadsUpMinutes, default: walkHeadsUpMinutes, in: 0...30)
        defaultLeadWarningMinutes = int(.defaultLeadWarningMinutes, default: defaultLeadWarningMinutes, in: 1...30)
        autoAdvanceEnabled = bool(.autoAdvanceEnabled, default: autoAdvanceEnabled)
        quickDeadlineHour = int(.quickDeadlineHour, default: quickDeadlineHour, in: 0...23)
        quickDeadlineMinute = int(.quickDeadlineMinute, default: quickDeadlineMinute, in: 0...59)
        developerModeEnabled = bool(.developerModeEnabled, default: developerModeEnabled)
        notificationSoundEnabled = bool(.notificationSoundEnabled, default: notificationSoundEnabled)
        leadWarningsEnabled = bool(.leadWarningsEnabled, default: leadWarningsEnabled)
        sequenceNewestFirst = bool(.sequenceNewestFirst, default: sequenceNewestFirst)
        startAlarmRoutineIds = d.stringArray(forKey: Key.startAlarmRoutineIds.rawValue) ?? []

        loading = false
    }
}
