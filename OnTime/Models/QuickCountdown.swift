import Foundation
import SwiftData

/// The persisted state behind `NowView`'s Final Time deadline. The step
/// sequence itself used to live here too (`QuickStep`, a bare-minutes-only
/// row with no name/kind/template) but `NowView` now edits real `Block`s
/// directly — see `NowView`'s doc comment — so the only thing left in this
/// file is the deadline shortcut chips, which stay independent of that.

/// A user-defined "tap to set the deadline" chip — e.g. "Work 17:30". Not
/// seeded with anything (no baked-in prayer times): the user adds their own
/// via the same "+ Add" affordance the prototype had.
@Model
final class QuickShortcut {
    var name: String = ""
    var hour: Int = 0
    var minute: Int = 0
    var order: Int = 0

    init(name: String, hour: Int, minute: Int, order: Int = 0) {
        self.name = name
        self.hour = hour
        self.minute = minute
        self.order = order
    }
}
