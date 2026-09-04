import Foundation
import SwiftData

/// Nulls every persisted pointer at a row before deleting it.
///
/// Four references in this schema are deliberately unpaired (no
/// `@Relationship` inverse): `Block.template`, `Block`'s and
/// `TaskTemplate`'s place pointers, and `Plan.routine`. SwiftData cannot
/// nullify an unpaired reference on delete, so a referrer left pointing at
/// a deleted row crashes with the uncatchable "backing data could no longer
/// be found" fatalError the next time any screen reads a property through
/// it — recurring on every launch until the store is wiped, because the
/// schema still matches and the rebuild policy never fires. Same idea as
/// `OnTimeApp.deleteOrphanedRuns`, applied before the delete instead of a
/// launch too late.
///
/// Every deletion affordance for these three types must come through here;
/// a bare `modelContext.delete` on any of them reintroduces the crash.
@MainActor
enum DeleteCleanup {
    static func delete(_ template: TaskTemplate, in context: ModelContext) {
        let id = template.persistentModelID
        for block in (try? context.fetch(FetchDescriptor<Block>())) ?? [] where block.template?.persistentModelID == id {
            block.template = nil
        }
        context.delete(template)
    }

    static func delete(_ place: Place, in context: ModelContext) {
        let id = place.persistentModelID
        for block in (try? context.fetch(FetchDescriptor<Block>())) ?? [] {
            if block.originPlace?.persistentModelID == id { block.originPlace = nil }
            if block.destinationPlace?.persistentModelID == id { block.destinationPlace = nil }
        }
        for template in (try? context.fetch(FetchDescriptor<TaskTemplate>())) ?? [] {
            if template.originPlace?.persistentModelID == id { template.originPlace = nil }
            if template.destinationPlace?.persistentModelID == id { template.destinationPlace = nil }
        }
        context.delete(place)
    }

    static func delete(_ routine: ScheduledRoutine, in context: ModelContext) {
        let id = routine.persistentModelID
        for plan in (try? context.fetch(FetchDescriptor<Plan>())) ?? [] where plan.routine?.persistentModelID == id {
            plan.routine = nil
        }
        context.delete(routine)
    }
}
