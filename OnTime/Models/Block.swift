import Foundation
import SwiftData

/// Where a block stands in its run.
enum BlockStatus: String, Codable, CaseIterable {
    case pending, active, done, skipped
}

/// One step of a `Plan` (or, as a template, of a `Routine`). Belongs to at
/// most one of `plan` / `routine` at a time — a `Block` that is part of a
/// routine's template sequence has `routine` set and `plan` nil; once a
/// routine spawns a concrete plan, later stages copy its blocks into fresh
/// `Block` rows owned by that `Plan` instead of sharing rows between the two.
@Model
final class Block {
    var order: Int = 0
    var name: String = ""
    var kindRaw: String = BlockKind.fixed.rawValue
    var template: TaskTemplate?
    var estimateOverrideMinutes: Int?
    var resolvedMinutes: Int = 0
    var originPlace: Place?
    var destinationPlace: Place?
    /// "Override Route — Use Estimate": when true, `TravelTimeService.resolve`
    /// skips live MapKit routing entirely for this block (no network, no
    /// GPS fix) and always reports the manual duration — for a route that's
    /// consistently wrong, flaky, or just not worth the wait. Origin/
    /// destination are left untouched so this can be flipped back on later.
    var useManualEstimateOnly: Bool = false
    /// Only meaningful for `kind == .startAt`: the clock time this block
    /// counts down to. Its effective duration is computed live as
    /// "time until targetHour:targetMinute", not stored as a fixed length —
    /// see `TravelTimeService.manualEstimateMinutes`.
    var targetHour: Int?
    var targetMinute: Int?
    var actualStart: Date?
    var actualEnd: Date?
    var statusRaw: String = BlockStatus.pending.rawValue
    /// Whether a `Run` bleeds straight into the next block once this one's
    /// timer is up, vs. waiting for a manual "Next Step" tap. Per-block
    /// override of `AppSettings.autoAdvanceEnabled` / `RunView`'s per-run
    /// toggle — both must allow auto-advance for a given block to actually
    /// skip the tap, so a block can be pinned to "always wait" (a step you
    /// deliberately want to time and confirm yourself) even with auto-advance
    /// on everywhere else. Defaults true: bleeding into the next step is the
    /// common case.
    var isOpenEnded: Bool = true

    var plan: Plan?
    var routine: ScheduledRoutine?

    init(order: Int, name: String, kind: BlockKind = .fixed,
         template: TaskTemplate? = nil, estimateOverrideMinutes: Int? = nil,
         resolvedMinutes: Int = 0, originPlace: Place? = nil,
         destinationPlace: Place? = nil, targetHour: Int? = nil,
         targetMinute: Int? = nil, status: BlockStatus = .pending,
         isOpenEnded: Bool = true, useManualEstimateOnly: Bool = false) {
        self.order = order
        self.name = name
        self.kindRaw = kind.rawValue
        self.template = template
        self.estimateOverrideMinutes = estimateOverrideMinutes
        self.resolvedMinutes = resolvedMinutes
        self.originPlace = originPlace
        self.destinationPlace = destinationPlace
        self.targetHour = targetHour
        self.targetMinute = targetMinute
        self.statusRaw = status.rawValue
        self.useManualEstimateOnly = useManualEstimateOnly
        self.isOpenEnded = isOpenEnded
    }

    var kind: BlockKind {
        get { BlockKind(rawValue: kindRaw) ?? .fixed }
        set { kindRaw = newValue.rawValue }
    }

    /// A fresh, unowned copy of this block for a spawning `Plan` to claim —
    /// configuration carried over, run state (`actualStart`/`actualEnd`/
    /// `status`) deliberately not.
    ///
    /// This exists because the two hand-rolled spawn loops it replaces each
    /// copied their own hand-picked subset of fields, and both of them
    /// dropped `isOpenEnded`, `useManualEstimateOnly`, `targetHour` and
    /// `targetMinute`. That silently made a routine incapable of carrying a
    /// `.startAt` step (its target time vanished, so its duration collapsed
    /// to "time until 00:00") or a step pinned to wait for a tap. Adding a
    /// field to `Block` and forgetting to add it here is the same bug
    /// again, so keep this exhaustive.
    func copyForSpawn(order: Int) -> Block {
        Block(
            order: order,
            name: name,
            kind: kind,
            template: template,
            estimateOverrideMinutes: estimateOverrideMinutes,
            resolvedMinutes: resolvedMinutes,
            originPlace: originPlace,
            destinationPlace: destinationPlace,
            targetHour: targetHour,
            targetMinute: targetMinute,
            isOpenEnded: isOpenEnded,
            useManualEstimateOnly: useManualEstimateOnly
        )
    }

    var status: BlockStatus {
        get { BlockStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
}
