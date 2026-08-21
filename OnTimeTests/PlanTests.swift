import Foundation
import Testing
import SwiftData
@testable import OnTime

struct PlanTests {
    @Test func spawningPlanFromRoutineCopiesBlocksWithoutSharing() {
        let routine = ScheduledRoutine(name: "Morning Prep", anchorHour: 7, anchorMinute: 30)
        let template = TaskTemplate(name: "Breakfast", manualEstimateMinutes: 15)
        let rBlock = Block(order: 0, name: "Breakfast", kind: .fixed, template: template, resolvedMinutes: 15)
        rBlock.routine = routine
        routine.blocks = [rBlock]
        routine.renumber()

        let plan = Plan(name: routine.name, deadline: Date().addingTimeInterval(3600), routine: routine)
        for (index, b) in routine.orderedBlocks.enumerated() {
            let copy = b.copyForSpawn(order: index)
            copy.plan = plan
            plan.blocks.append(copy)
        }
        plan.renumber()

        #expect(plan.orderedBlocks.count == 1)
        #expect(routine.orderedBlocks.count == 1)
        // Assert block rows are distinct instances
        #expect(plan.orderedBlocks.first !== routine.orderedBlocks.first)
        #expect(plan.orderedBlocks.first?.plan === plan)
        #expect(routine.orderedBlocks.first?.routine === routine)
    }

    /// The copy loops this replaced each picked their own subset of fields to
    /// carry over, and both dropped these four — which silently made a
    /// routine unable to hold a `.startAt` step (its target time vanished, so
    /// its duration collapsed to "time until 00:00") or a step pinned to wait
    /// for a tap. The old version of the test above asserted the copies
    /// weren't *shared* but never that they were *faithful*, which is exactly
    /// why that went unnoticed.
    @Test func spawnCopyCarriesEveryConfiguredField() {
        let origin = Place(name: "Home", latitude: 38.0, longitude: -84.5)
        let destination = Place(name: "Masjid", latitude: 38.1, longitude: -84.4)
        let template = TaskTemplate(name: "Drive", kind: .drive, manualEstimateMinutes: 12)

        let source = Block(
            order: 3,
            name: "Drive to masjid",
            kind: .drive,
            template: template,
            estimateOverrideMinutes: 9,
            resolvedMinutes: 11,
            originPlace: origin,
            destinationPlace: destination,
            targetHour: 17,
            targetMinute: 45,
            isOpenEnded: false,
            useManualEstimateOnly: true
        )

        let copy = source.copyForSpawn(order: 0)

        #expect(copy.order == 0)
        #expect(copy.name == source.name)
        #expect(copy.kind == .drive)
        #expect(copy.template === template)
        #expect(copy.estimateOverrideMinutes == 9)
        #expect(copy.resolvedMinutes == 11)
        #expect(copy.originPlace === origin)
        #expect(copy.destinationPlace === destination)
        // The four that used to be dropped.
        #expect(copy.targetHour == 17)
        #expect(copy.targetMinute == 45)
        #expect(copy.isOpenEnded == false)
        #expect(copy.useManualEstimateOnly == true)
    }

    /// Run state belongs to the run that recorded it, never to a fresh copy.
    @Test func spawnCopyDoesNotCarryRunState() {
        let source = Block(order: 0, name: "Shower", kind: .fixed)
        source.actualStart = Date()
        source.actualEnd = Date().addingTimeInterval(600)
        source.status = .done

        let copy = source.copyForSpawn(order: 0)

        #expect(copy.actualStart == nil)
        #expect(copy.actualEnd == nil)
        #expect(copy.status == .pending)
    }
}
