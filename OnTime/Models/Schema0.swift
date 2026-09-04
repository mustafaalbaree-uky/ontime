import Foundation
import SwiftData

/// The full list of persisted model types, versioned the same way
/// shadiliya's `Schema0` is: a model added here but not to
/// `ModelContainer(for: Schema(Schema0.models))` simply has no table, and
/// every fetch of it silently returns nothing rather than erroring.
enum Schema0 {
    static let models: [any PersistentModel.Type] = [
        TaskTemplate.self, DurationSample.self,
        Place.self,
        Plan.self, Block.self,
        Run.self,
        ScheduledRoutine.self,
        QuickShortcut.self,
        WorkSession.self
    ]
}
