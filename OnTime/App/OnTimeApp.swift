import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct OnTimeApp: App {

    @State private var settings = AppSettings.shared
    private let container: ModelContainer

    /// The opportunistic third layer of routine arming. iOS decides if and
    /// when this ever runs, so nothing depends on it: the arm notification
    /// is the guaranteed layer and foregrounding is the common one. This
    /// just means that if the system happens to give us a moment during the
    /// arm window, the Live Activity is already up before the phone is even
    /// unlocked.
    static let armTaskIdentifier = "com.mammer55.ontime.armroutines"

    init() {
        // Local store in Application Support. Deliberately not a cache
        // directory, so nothing here is evictable under storage pressure.
        let config = ModelConfiguration("OnTimeStore", isStoredInMemoryOnly: false)
        do {
            // The list comes from `Schema0` rather than being spelled out
            // here — see that file's comment for why.
            container = try Self.openStore(config: config)
            Self.deleteOrphanedRuns(in: container)
            Task { @MainActor in
                Notifications.shared.registerCategories()
                _ = await Notifications.shared.requestAuthorization()
            }
            // Kicks off the location permission prompt (or a one-shot fix
            // if already granted) at launch rather than waiting for the
            // user to open Settings — a drive block's "Current Location"
            // origin is otherwise silently (0, 0) until that happens.
            LocationService.shared.requestLocation()
            registerArmTask(container: container)
        } catch {
            fatalError("Could not open the store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container)
                .onAppear { Self.scheduleArmTask() }
        }
    }

    /// Opens the store, rebuilding it from scratch if the on-disk schema no
    /// longer matches `Schema0.models`.
    ///
    /// There is no `VersionedSchema`/`MigrationPlan` here, so any model
    /// change — a type removed, a property added — makes the existing store
    /// unopenable, which previously meant `fatalError` on launch and an app
    /// that could only be recovered by deleting it from the phone. Nothing
    /// in this app is irreplaceable (a routine is a name, a time and a few
    /// steps; the durations it has learned re-accumulate), so trading the
    /// contents for a launchable app is the right way round. If that ever
    /// stops being true, this is the function that has to grow a real
    /// migration plan instead.
    private static func openStore(config: ModelConfiguration) throws -> ModelContainer {
        let schema = Schema(Schema0.models)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            print("Store incompatible (\(error)) — rebuilding it.")
            if let url = config.url as URL? {
                // Core Data keeps the WAL and shared-memory sidecars beside
                // the store; leaving them behind makes the fresh store fail
                // to open too.
                for suffix in ["", "-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: url.path + suffix)
                    try? FileManager.default.removeItem(at: sidecar)
                }
            }
            return try ModelContainer(for: schema, configurations: config)
        }
    }

    /// Must be registered before the app finishes launching, hence `init`.
    private func registerArmTask(container: ModelContainer) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.armTaskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                // A fresh context: this runs with no view hierarchy, so
                // there is no environment `modelContext` to borrow.
                let context = ModelContext(container)
                ScheduleService.armDueRoutines(in: context)
                ScheduleService.refreshArmAlarms(in: context)
                try? context.save()
                Self.scheduleArmTask()
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// Re-submitted after every run — a `BGAppRefreshTaskRequest` is one-shot.
    static func scheduleArmTask() {
        let request = BGAppRefreshTaskRequest(identifier: armTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// A `Run` whose `Plan` got deleted before `Plan.runs`' cascade delete
    /// rule existed is left pointing at a backing row that's simply gone —
    /// SwiftData only discovers that the moment something reads a property
    /// off the stale `Plan` reference, which is an uncatchable fatalError
    /// ("This model instance was invalidated..."), not a normal Swift
    /// error. This has to run here, synchronously, before `RootView` (or
    /// any of its tabs — `CountdownsView`'s `@Query<Run>` in particular)
    /// gets a chance to construct a single view: SwiftUI does not guarantee
    /// `RootView`'s own `.task` runs before sibling tabs' `onAppear`, and
    /// `CountdownsView`'s row `onAppear` builds a `RunEngine` straight from
    /// the query result, so a cleanup that ran any later than this was
    /// racing a crash it usually lost.
    ///
    /// `persistentModelID` is safe to read on a stale reference (it's
    /// already known, not faulted from the store); cross-checking it
    /// against a fresh fetch of live `Plan`s tells us whether `run.plan` is
    /// real without ever touching a property that would fault.
    private static func deleteOrphanedRuns(in container: ModelContainer) {
        let context = ModelContext(container)
        let openRuns = (try? context.fetch(FetchDescriptor<Run>(predicate: #Predicate { $0.finishedAt == nil }))) ?? []
        guard !openRuns.isEmpty else { return }

        let livePlanIDs = Set(((try? context.fetch(FetchDescriptor<Plan>())) ?? []).map(\.persistentModelID))
        for run in openRuns {
            let planIsLive = run.plan.map { livePlanIDs.contains($0.persistentModelID) } ?? false
            if !planIsLive {
                context.delete(run)
            }
        }
        try? context.save()
    }
}
