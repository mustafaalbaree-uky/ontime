import Foundation
import SwiftData

/// Which sort of thing a block is, before it is scheduled. Drives how a
/// block's duration is treated by later stages (fixed blocks don't flex,
/// drive blocks pull from travel time, flex blocks absorb slack, `startAt`
/// blocks count down to a clock time instead of a fixed length).
enum BlockKind: String, Codable, CaseIterable {
    case fixed, drive, flex, startAt

    /// SF Symbol used wherever a block has no `template` (and so no symbol
    /// of its own) to fall back to — one place so every call site (`NowView`,
    /// `PlanEditorView`, the Live Activity) agrees, and so a new case here
    /// can't compile without a symbol decision. Deliberately nothing
    /// circular for `.fixed`/`.startAt` — a plain filled circle reads as a
    /// bullet, not a step.
    var defaultSymbol: String {
        switch self {
        case .fixed: return "square.fill"
        case .drive: return "car.fill"
        case .flex: return "arrow.left.and.right"
        case .startAt: return "alarm.fill"
        }
    }
}

/// A reusable kind of task ("Shower", "Drive to masjid") that a `Block` can be
/// stamped from. Keeps a running history of how long it actually took
/// (`samples`) so later stages can estimate durations instead of trusting the
/// manual guess forever.
@Model
final class TaskTemplate {
    var name: String = ""
    /// SF Symbol name.
    var symbol: String = "square.fill"
    var kindRaw: String = BlockKind.fixed.rawValue
    var manualEstimateMinutes: Int = 10
    var createdAt: Date = Date()
    /// Remembered route for a drive template, so picking it from the title
    /// autocomplete in `QuickBlockEditorSheet` fills in "From"/"To" too, not
    /// just the name/kind/duration. `originPlace` may be the "Current
    /// Location" sentinel (see `Place.isCurrentLocation`) — that's a live
    /// reference, re-resolved against the GPS on every future use, same as
    /// it is for an ordinary `Block`. It only ever becomes a fixed address
    /// if the user explicitly turns off "Follow My Location" while saving,
    /// which snapshots a new fixed `Place` here instead — see
    /// `QuickBlockEditorSheet.save()`.
    var originPlace: Place?
    var destinationPlace: Place?
    /// Skip live MapKit routing for any block stamped from this template and
    /// just use the manual estimate — the per-block "Override Route" toggle
    /// carries over into new steps made from this template. A block can
    /// still flip it back on for itself; this is only the default.
    var useManualEstimateOnly: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \DurationSample.template)
    var samples: [DurationSample] = []

    init(name: String, symbol: String = "circle", kind: BlockKind = .fixed,
         manualEstimateMinutes: Int = 10, createdAt: Date = Date(),
         originPlace: Place? = nil, destinationPlace: Place? = nil,
         useManualEstimateOnly: Bool = false) {
        self.name = name
        self.symbol = symbol
        self.kindRaw = kind.rawValue
        self.manualEstimateMinutes = manualEstimateMinutes
        self.createdAt = createdAt
        self.originPlace = originPlace
        self.destinationPlace = destinationPlace
        self.useManualEstimateOnly = useManualEstimateOnly
    }

    var kind: BlockKind {
        get { BlockKind(rawValue: kindRaw) ?? .fixed }
        set { kindRaw = newValue.rawValue }
    }
}

/// One observed duration for a `TaskTemplate`, logged after a run actually
/// completes the block. Later stages use these to build an estimate that
/// tracks reality instead of the original manual guess.
@Model
final class DurationSample {
    var minutes: Int = 0
    var recordedAt: Date = Date()
    var template: TaskTemplate?

    init(minutes: Int, recordedAt: Date = Date(), template: TaskTemplate? = nil) {
        self.minutes = minutes
        self.recordedAt = recordedAt
        self.template = template
    }
}
