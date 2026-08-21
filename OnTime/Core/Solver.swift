import Foundation

/// One block's duration: either known up front, or the single block whose
/// duration is solved for (see `Solver`).
enum BlockDuration: Equatable {
    case known(TimeInterval)
    case flex
}

/// Why a block's `leaveBy` time is what it is.
enum BlockConstraint: Equatable {
    /// Everything after this block has a known duration, so this is a real
    /// wall-clock deadline for finishing the block.
    case hardLeaveBy(Date)
    /// The flex block is still ahead, so lateness here does not move `E`;
    /// it shrinks the flex block instead. Carries the flex time currently
    /// remaining, which the UI shows counting down live.
    case flexAbsorbs(remainingFlex: TimeInterval)
}

/// The inputs to `Solver.solve`. Exactly one of `start` / the flex block's
/// duration must be unknown — see `SolverError`.
struct SolverInput {
    var durations: [BlockDuration]
    var deadline: Date
    /// nil = solve for the start time (requires no flex block, since two
    /// unknowns can't be solved from one equation).
    var start: Date?
    /// Set once the user actually enters the flex block, so its countdown
    /// stops drifting while they're busy inside it. When set, the flex
    /// block is treated as a known duration for every purpose below,
    /// including which blocks get `.hardLeaveBy`.
    var pinnedFlex: TimeInterval?
}

struct BlockSchedule: Equatable {
    var index: Int
    /// The resolved duration — for the flex block this is the solved (or
    /// pinned) flex value.
    var duration: TimeInterval
    var scheduledStart: Date
    var scheduledEnd: Date
    var constraint: BlockConstraint
}

struct Solution: Equatable {
    var start: Date
    var flexIndex: Int?
    var flexDuration: TimeInterval?
    var blocks: [BlockSchedule]
    /// How far past `deadline` the plan now runs. > 0 is over the deadline,
    /// <= 0 is slack. Never rolled forward a day to hide lateness.
    var lateness: TimeInterval
}

enum SolverError: Error, Equatable {
    case multipleFlexBlocks
    case underdetermined
    case overdetermined
    case empty
}

enum Solver {
    static func solve(_ input: SolverInput) throws -> Solution {
        guard !input.durations.isEmpty else { throw SolverError.empty }

        let flexIndices = input.durations.indices.filter { input.durations[$0] == .flex }
        guard flexIndices.count <= 1 else { throw SolverError.multipleFlexBlocks }
        let flexIndex = flexIndices.first

        if flexIndex == nil {
            // No flex block: if `start` is nil, solve for start:
            // start = deadline - sum(known durations).
            // If `start` was given, we accept it and validate against deadline via lateness.
            let resolved = input.durations.compactMap { d -> TimeInterval? in
                if case .known(let v) = d { return v }
                return nil
            }
            let sumKnown = resolved.reduce(0, +)
            let start = input.start ?? input.deadline.addingTimeInterval(-sumKnown)
            return buildSolution(input: input, start: start, flexIndex: nil,
                                  flexDuration: nil, resolvedDurations: resolved)
        }

        let fi = flexIndex!

        if let pinned = input.pinnedFlex {
            // Pinned: flex duration is fixed, so nothing is left unknown
            // except (possibly) start, which must still be supplied — a
            // flex block's presence means `start` is never solved-for.
            guard let start = input.start else { throw SolverError.underdetermined }
            var resolved = [TimeInterval](repeating: 0, count: input.durations.count)
            for (i, d) in input.durations.enumerated() {
                if case .known(let v) = d { resolved[i] = v }
            }
            resolved[fi] = pinned
            return buildSolution(input: input, start: start, flexIndex: fi,
                                  flexDuration: pinned, resolvedDurations: resolved)
        }

        // Unpinned flex block: start must be given; solve for the flex
        // duration algebraically.
        guard let start = input.start else { throw SolverError.underdetermined }
        var resolved = [TimeInterval](repeating: 0, count: input.durations.count)
        var knownSum: TimeInterval = 0
        for (i, d) in input.durations.enumerated() {
            if case .known(let v) = d {
                resolved[i] = v
                knownSum += v
            }
        }
        let flexValue = input.deadline.timeIntervalSince(start) - knownSum
        resolved[fi] = flexValue
        return buildSolution(input: input, start: start, flexIndex: fi,
                              flexDuration: flexValue, resolvedDurations: resolved)
    }

    private static func buildSolution(
        input: SolverInput,
        start: Date,
        flexIndex: Int?,
        flexDuration: TimeInterval?,
        resolvedDurations: [TimeInterval]
    ) -> Solution {
        let n = resolvedDurations.count

        // suffixAfter[i] = sum(resolvedDurations[j] for j > i)
        var suffixAfter = [TimeInterval](repeating: 0, count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let next = (i + 1 < n) ? resolvedDurations[i + 1] : 0
            suffixAfter[i] = suffixAfter[i + 1] + next
        }

        var scheduledStarts = [Date](repeating: start, count: n)
        var elapsed: TimeInterval = 0
        for i in 0..<n {
            scheduledStarts[i] = start.addingTimeInterval(elapsed)
            elapsed += resolvedDurations[i]
        }

        // Pinning collapses the flex block into an ordinary known block for
        // constraint purposes: nothing after it is unknown, so it and
        // everything downstream (indeed everything, since it's no longer
        // "the flex block" for this purpose) gets `.hardLeaveBy`.
        let isPinned = input.pinnedFlex != nil
        let absorbBoundary = isPinned ? nil : flexIndex // blocks before this index absorb

        var blocks: [BlockSchedule] = []
        blocks.reserveCapacity(n)
        for i in 0..<n {
            let scheduledStart = scheduledStarts[i]
            let scheduledEnd = scheduledStart.addingTimeInterval(resolvedDurations[i])
            let leaveBy = input.deadline.addingTimeInterval(-suffixAfter[i])

            let constraint: BlockConstraint
            if let boundary = absorbBoundary, i < boundary {
                constraint = .flexAbsorbs(remainingFlex: flexDuration ?? 0)
            } else {
                constraint = .hardLeaveBy(leaveBy)
            }

            blocks.append(BlockSchedule(
                index: i,
                duration: resolvedDurations[i],
                scheduledStart: scheduledStart,
                scheduledEnd: scheduledEnd,
                constraint: constraint
            ))
        }

        let planEnd = start.addingTimeInterval(elapsed)
        let lateness = planEnd.timeIntervalSince(input.deadline)

        return Solution(
            start: start,
            flexIndex: flexIndex,
            flexDuration: flexDuration,
            blocks: blocks,
            lateness: lateness
        )
    }
}
