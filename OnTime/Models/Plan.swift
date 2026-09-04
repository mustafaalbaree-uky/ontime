import Foundation
import SwiftData

/// A concrete sequence of blocks working toward one `deadline`.
@Model
final class Plan {
    /// Stable identity for everything outside the store: Live Activity
    /// `planId`s, notification identifiers, and the intent round trip. A
    /// `persistentModelID` is temporary until the first save, so keys
    /// derived from it could change under the run after autosave — minting
    /// a duplicate Live Activity and orphaning notification bookkeeping.
    var uuid: UUID = UUID()
    var name: String = ""
    var deadline: Date = Date()
    var createdAt: Date = Date()
    /// Provenance only: which `ScheduledRoutine` this plan was spawned from,
    /// so an armed run can be traced back to the routine that armed it. Not
    /// a source of truth for anything — the blocks are copies.
    var routine: ScheduledRoutine?

    @Relationship(deleteRule: .cascade, inverse: \Block.plan)
    var blocks: [Block] = []

    // Deliberately NOT `@Relationship(inverse: \Run.plan)`: making that
    // bidirectional means deleting a `Run` whose `Plan` row is already gone
    // (see `OnTimeApp.deleteOrphanedRuns`) makes SwiftData/Core Data try to
    // update the *inverse* side of the relationship on delete — which means
    // faulting in that already-gone `Plan`, which crashes with the exact
    // "backing data could no longer be found" fatalError this is trying to
    // clean up, just moved from a property read to `context.save()`.
    // `Run.plan` stays a one-way pointer; `OnTimeApp.deleteOrphanedRuns`
    // deletes a `Plan`'s `Run`s by
    // fetching them via predicate instead of relying on this relationship's
    // own delete rule.

    init(name: String, deadline: Date, createdAt: Date = Date(), routine: ScheduledRoutine? = nil) {
        self.name = name
        self.deadline = deadline
        self.createdAt = createdAt
        self.routine = routine
    }

    /// `blocks` is a SwiftData relationship array, which SwiftData does **not**
    /// keep in insertion or any other stable order — reading `blocks` directly
    /// can hand back a different order every fetch. Every view must go through
    /// this instead of touching `blocks` for display.
    var orderedBlocks: [Block] {
        blocks.sorted { $0.order < $1.order }
    }

    /// Rewrites `order` on every block to a clean 0...n-1 sequence, in the
    /// blocks' *current* `orderedBlocks` order. Call this after any move,
    /// insert, or delete — leaving gaps or duplicate `order` values is what
    /// makes `orderedBlocks` ambiguous or unstable on the next fetch.
    func renumber() {
        for (index, block) in orderedBlocks.enumerated() {
            block.order = index
        }
    }

    /// Clears every block's run-in-progress state (`actualStart`,
    /// `actualEnd`, `status`) back to fresh. `Block`s belong to the `Plan`,
    /// not to any one `Run` — so without this, starting a *new* `Run` over a
    /// plan that still carries stamps from an earlier canceled/finished run
    /// left the new run reading those blocks as already `.done`/`.active`
    /// with timestamps from the old run, which looked like the sequence had
    /// been silently corrupted. Call this immediately before creating a new
    /// `Run` against this plan.
    func resetForNewRun() {
        for block in blocks {
            block.actualStart = nil
            block.actualEnd = nil
            block.status = .pending
        }
    }
}
