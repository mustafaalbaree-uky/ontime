import Foundation
import SwiftData

/// One live execution of a `Plan` — the thing the running-clock screen (a
/// later stage) actually drives.
@Model
final class Run {
    /// Stable identity for `RunEngineStore`'s engine map and the walk
    /// tracker's ownership check — see `Plan.uuid` for why a
    /// `persistentModelID` is not usable as a key here.
    var uuid: UUID = UUID()
    var plan: Plan?
    var startedAt: Date = Date()
    var currentIndex: Int = 0
    /// A flex block's minutes, pinned once the run starts so later
    /// re-solves don't yank time out from under a block already in progress.
    var pinnedFlexMinutes: Int?
    var finishedAt: Date?

    init(plan: Plan? = nil, startedAt: Date = Date(), currentIndex: Int = 0,
         pinnedFlexMinutes: Int? = nil, finishedAt: Date? = nil) {
        self.plan = plan
        self.startedAt = startedAt
        self.currentIndex = currentIndex
        self.pinnedFlexMinutes = pinnedFlexMinutes
        self.finishedAt = finishedAt
    }
}
