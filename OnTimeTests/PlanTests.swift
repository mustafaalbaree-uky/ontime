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

        source.resolvedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let copy = source.copyForSpawn(order: 0)

        #expect(copy.order == 0)
        #expect(copy.name == source.name)
        #expect(copy.kind == .drive)
        #expect(copy.template === template)
        #expect(copy.estimateOverrideMinutes == 9)
        #expect(copy.resolvedMinutes == 11)
        #expect(copy.resolvedAt == source.resolvedAt)
        #expect(copy.originPlace === origin)
        #expect(copy.destinationPlace === destination)
        // The four that used to be dropped.
        #expect(copy.targetHour == 17)
        #expect(copy.targetMinute == 45)
        #expect(copy.isOpenEnded == false)
        #expect(copy.useManualEstimateOnly == true)
        // Identity is per-row, never copied.
        #expect(copy.uuid != source.uuid)
    }

    /// The mechanical tripwire the hand-written test above cannot be: it
    /// asserts only the fields it already names, so the exact recurring bug
    /// it exists to catch (a new `Block` field missing from `copyForSpawn`)
    /// sailed past it — the developer who forgets the copy also never adds
    /// the assertion. This walks the *schema's* property list for Block and
    /// fails on any field that is in neither the copied list nor the
    /// deliberate-exclusion list, forcing an explicit decision.
    @Test func copyForSpawnAccountsForEveryPersistedBlockField() throws {
        let schema = Schema(Schema0.models)
        let entity = try #require(schema.entities.first { $0.name == "Block" })
        let persisted = Set(entity.attributes.map(\.name))
            .union(entity.relationships.map(\.name))

        let copied: Set<String> = [
            "order", "name", "kindRaw", "template", "estimateOverrideMinutes",
            "resolvedMinutes", "resolvedAt", "originPlace", "destinationPlace",
            "targetHour", "targetMinute", "isOpenEnded", "useManualEstimateOnly",
        ]
        // Run state belongs to the run that recorded it; ownership belongs
        // to the spawner; identity is per-row.
        let deliberatelyExcluded: Set<String> = [
            "uuid", "actualStart", "actualEnd", "statusRaw", "plan", "routine",
        ]

        let unaccounted = persisted.subtracting(copied).subtracting(deliberatelyExcluded)
        #expect(unaccounted.isEmpty,
                "New Block field(s) \(unaccounted.sorted()) must be added to copyForSpawn and this test's copied list, or explicitly excluded")
    }

    /// One row of every model type through a real container over
    /// `Schema0.models`. This is the only automated way to catch the silent
    /// failure the Schema0 comment warns about: a model added to the code
    /// but not to that list has no table, and every fetch of it returns
    /// empty with no error anywhere.
    @Test func schema0RoundTripsEveryModelType() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(Schema0.models), configurations: config)
        let context = ModelContext(container)

        let template = TaskTemplate(name: "T")
        context.insert(template)
        context.insert(DurationSample(minutes: 5, template: template))
        context.insert(Place(name: "P"))
        let plan = Plan(name: "Plan", deadline: Date())
        context.insert(plan)
        let block = Block(order: 0, name: "B")
        block.plan = plan
        context.insert(block)
        context.insert(Run(plan: plan))
        context.insert(ScheduledRoutine(name: "R", anchorHour: 7, anchorMinute: 0))
        context.insert(QuickShortcut(name: "Q", hour: 9, minute: 0))
        try context.save()

        #expect(try context.fetch(FetchDescriptor<TaskTemplate>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<DurationSample>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Place>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Plan>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Block>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Run>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ScheduledRoutine>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<QuickShortcut>()).count == 1)
    }

    /// The dangling-pointer cleanup: deleting a template, place, or routine
    /// through `DeleteCleanup` nils every unpaired referrer first, so no
    /// later property read faults on a deleted row.
    @MainActor
    @Test func deleteCleanupNilsUnpairedReferrers() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(Schema0.models), configurations: config)
        let context = ModelContext(container)

        let template = TaskTemplate(name: "Shower")
        let place = Place(name: "Masjid", latitude: 38, longitude: -84)
        let routine = ScheduledRoutine(name: "Evening", anchorHour: 19, anchorMinute: 30)
        context.insert(template)
        context.insert(place)
        context.insert(routine)

        let block = Block(order: 0, name: "Step", kind: .drive, template: template, destinationPlace: place)
        context.insert(block)
        let plan = Plan(name: "P", deadline: Date(), routine: routine)
        context.insert(plan)
        try context.save()

        DeleteCleanup.delete(template, in: context)
        DeleteCleanup.delete(place, in: context)
        DeleteCleanup.delete(routine, in: context)
        try context.save()

        #expect(block.template == nil)
        #expect(block.destinationPlace == nil)
        #expect(plan.routine == nil)
        #expect(try context.fetch(FetchDescriptor<TaskTemplate>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ScheduledRoutine>()).isEmpty)
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
