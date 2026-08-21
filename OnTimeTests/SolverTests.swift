import Foundation
import Testing
@testable import OnTime

struct SolverTests {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 19) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    // MARK: 1. Solve for S, no flex block.

    @Test func solvesForStartWithNoFlexBlock() throws {
        let deadline = date(19, 30)
        let input = SolverInput(
            durations: [.known(TimeInterval(7 * 60)), .known(TimeInterval(12 * 60))],
            deadline: deadline,
            start: nil,
            pinnedFlex: nil
        )
        let solution = try Solver.solve(input)
        #expect(solution.start == date(19, 11))
        #expect(solution.lateness == 0)
        #expect(solution.flexIndex == nil)
    }

    // MARK: 2. Cat/vet case: solve for flex duration.

    private func catVetInput(start: Date, deadline: Date, extraFirstLeg: TimeInterval = 0) -> SolverInput {
        SolverInput(
            durations: [
                .known(TimeInterval(10 * 60) + extraFirstLeg), // drive to other house
                .flex,                            // task at the house
                .known(TimeInterval(10 * 60)),                  // drive back
                .known(TimeInterval(5 * 60)),                   // put cat in carrier
                .known(TimeInterval(15 * 60)),                  // drive to vet
            ],
            deadline: deadline,
            start: start,
            pinnedFlex: nil
        )
    }

    @Test func solvesForFlexDuration() throws {
        let start = date(12, 0)
        let deadline = start.addingTimeInterval(75 * 60)
        let solution = try Solver.solve(catVetInput(start: start, deadline: deadline))
        #expect(solution.flexIndex == 1)
        #expect(try #require(solution.flexDuration) == TimeInterval(35 * 60))
        #expect(solution.lateness == 0)
    }

    // MARK: 3. Pre-flex blocks absorb; flex block and later are hard.

    @Test func preFlexBlocksAbsorbAndPostFlexBlocksAreHard() throws {
        let start = date(12, 0)
        let deadline = start.addingTimeInterval(75 * 60)
        let solution = try Solver.solve(catVetInput(start: start, deadline: deadline))

        guard case .flexAbsorbs = solution.blocks[0].constraint else {
            Issue.record("expected block 0 (pre-flex) to be .flexAbsorbs")
            return
        }
        for i in 1..<solution.blocks.count {
            guard case .hardLeaveBy = solution.blocks[i].constraint else {
                Issue.record("expected block \(i) to be .hardLeaveBy")
                return
            }
        }
    }

    // MARK: 4. hardLeaveBy values are invariant under a later start.

    @Test func hardLeaveByInvariantUnderLateStart() throws {
        let start = date(12, 0)
        let deadline = start.addingTimeInterval(75 * 60)
        let onTime = try Solver.solve(catVetInput(start: start, deadline: deadline))

        let lateStart = start.addingTimeInterval(10 * 60)
        let late = try Solver.solve(catVetInput(start: lateStart, deadline: deadline))

        for i in 1..<onTime.blocks.count {
            guard case .hardLeaveBy(let onTimeDate) = onTime.blocks[i].constraint,
                  case .hardLeaveBy(let lateDate) = late.blocks[i].constraint else {
                Issue.record("expected .hardLeaveBy on block \(i) in both solutions")
                return
            }
            #expect(onTimeDate == lateDate)
        }
    }

    // MARK: 5. Overrunning a pre-flex block shrinks flex 1:1.

    @Test func preFlexOverrunShrinksFlexOneToOne() throws {
        let start = date(12, 0)
        let deadline = start.addingTimeInterval(75 * 60)
        let base = try Solver.solve(catVetInput(start: start, deadline: deadline))
        let overrun = try Solver.solve(catVetInput(start: start, deadline: deadline, extraFirstLeg: 5 * 60))

        #expect(base.flexDuration! - overrun.flexDuration! == 5 * 60)

        for i in 1..<base.blocks.count {
            guard case .hardLeaveBy(let baseDate) = base.blocks[i].constraint,
                  case .hardLeaveBy(let overrunDate) = overrun.blocks[i].constraint else {
                Issue.record("expected .hardLeaveBy on block \(i) in both solutions")
                return
            }
            #expect(baseDate == overrunDate)
        }
    }

    // MARK: 6. Pinning forces every block to .hardLeaveBy and resists upstream drift.

    @Test func pinningForcesHardLeaveByEverywhere() throws {
        let start = date(12, 0)
        let deadline = start.addingTimeInterval(75 * 60)
        var input = catVetInput(start: start, deadline: deadline)
        input.pinnedFlex = 35 * 60
        let solution = try Solver.solve(input)

        for block in solution.blocks {
            guard case .hardLeaveBy = block.constraint else {
                Issue.record("expected .hardLeaveBy on block \(block.index) when pinned")
                return
            }
        }
        #expect(try #require(solution.flexDuration) == TimeInterval(35 * 60))

        // Upstream drift (a later start) must not change the pinned value.
        var driftedInput = input
        driftedInput.start = start.addingTimeInterval(20 * 60)
        let drifted = try Solver.solve(driftedInput)
        #expect(try #require(drifted.flexDuration) == TimeInterval(35 * 60))
    }

    // MARK: 7. Negative flex is legal.

    @Test func negativeFlexIsNotClamped() throws {
        let start = date(12, 0)
        // Only 30 min available but 40 min of known blocks — 10 min short.
        let deadline = start.addingTimeInterval(30 * 60)
        let solution = try Solver.solve(catVetInput(start: start, deadline: deadline))
        #expect(try #require(solution.flexDuration) == TimeInterval(-10 * 60))
    }

    // MARK: 8. Errors.

    @Test func multipleFlexBlocksThrows() {
        let start = date(12, 0)
        let input = SolverInput(
            durations: [.flex, .known(TimeInterval(5 * 60)), .flex],
            deadline: start.addingTimeInterval(60 * 60),
            start: start,
            pinnedFlex: nil
        )
        #expect(throws: SolverError.multipleFlexBlocks) {
            try Solver.solve(input)
        }
    }

    @Test func nilStartWithFlexBlockIsUnderdetermined() {
        let input = SolverInput(
            durations: [.known(TimeInterval(5 * 60)), .flex],
            deadline: date(19, 30),
            start: nil,
            pinnedFlex: nil
        )
        #expect(throws: SolverError.underdetermined) {
            try Solver.solve(input)
        }
    }

    @Test func emptyDurationsThrows() {
        let input = SolverInput(durations: [], deadline: date(19, 30), start: nil, pinnedFlex: nil)
        #expect(throws: SolverError.empty) {
            try Solver.solve(input)
        }
    }
}
