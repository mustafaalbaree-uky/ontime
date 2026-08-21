import Foundation
import Testing
@testable import OnTime

/// Proves the test target is wired to the app target and actually runs.
/// Later stages add the real solver tests alongside this.
struct OnTimeTests {
    @Test func planRenumberProducesSequentialOrder() {
        let plan = Plan(name: "Test Plan", deadline: Date())
        let a = Block(order: 5, name: "A")
        let b = Block(order: 2, name: "B")
        let c = Block(order: 9, name: "C")
        plan.blocks = [a, b, c]
        plan.renumber()

        #expect(plan.orderedBlocks.map(\.name) == ["B", "A", "C"])
        #expect(plan.orderedBlocks.map(\.order) == [0, 1, 2])
    }
}
