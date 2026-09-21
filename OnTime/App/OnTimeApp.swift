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
            let launchContainer = container
            MainActor.assumeIsolated {
                // Synchronously, before launch finishes: the notification
                // center delegate must exist before the launch sequence can
                // deliver a notification response (a cold launch from a
                // "Next Step" action otherwise drops the tap), and touching
                // RunEngineStore here registers the Complete Step observer
                // for the same reason. Only the authorization *request*
                // stays async.
                Notifications.shared.registerCategories()
                RunEngineStore.shared.configure(modelContext: launchContainer.mainContext)
                // Same context, same moment. The BG arm task can run with no
                // view hierarchy ever appearing, and it is exactly the pass
                // that turns an upcoming routine into a live run — the one
                // change the Home Screen widget most needs to hear about.
                WidgetBridge.shared.configure(modelContext: launchContainer.mainContext)
                PushTokens.startObserving(modelContext: launchContainer.mainContext)
            }
            Task { @MainActor in
                _ = await Notifications.shared.requestAuthorization()
            }
            // Kicks off the location permission prompt (or a one-shot fix
            // if already granted) at launch rather than waiting for the
            // user to open Settings — a drive block's "Current Location"
            // origin is otherwise silently (0, 0) until that happens.
            MainActor.assumeIsolated {
                LocationService.shared.requestLocation()
            }
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
            // One immediate retry first: `ModelContainer` can throw for
            // transient reasons (a file lock, disk pressure) that have
            // nothing to do with the schema, and rebuilding on those would
            // trade recoverable data for nothing.
            if let second = try? ModelContainer(for: schema, configurations: config) {
                return second
            }
            print("Store failed to open twice (\(error)) — moving it aside and rebuilding.")
            if let url = config.url as URL? {
                // Moved aside with a timestamp, never deleted: if the
                // failure turns out to have been transient after all, the
                // bytes are still on disk to recover by hand. Core Data
                // keeps the WAL and shared-memory sidecars beside the
                // store; they travel with it or the fresh store fails to
                // open too.
                let stamp = Int(Date().timeIntervalSince1970)
                for suffix in ["", "-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: url.path + suffix)
                    guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
                    let backup = URL(fileURLWithPath: url.path + suffix + ".incompatible-\(stamp)")
                    try? FileManager.default.moveItem(at: sidecar, to: backup)
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
                // The view hierarchy's own context, NOT a throwaway
                // `ModelContext(container)`: a hand-made context has
                // autosave off, so a run armed here lived in a context
                // nothing ever saved again, and its engine's later writes
                // crossed wires with the view context on the next
                // foreground.
                ScheduleService.catchUp(in: container.mainContext)
                do {
                    try container.mainContext.save()
                } catch {
                    print("BG arm task save failed: \(error)")
                }
                WidgetBridge.shared.refresh()
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
        // Every run, not only open ones: a *finished* run with a dead plan
        // pointer persists forever and becomes a guaranteed crash the
        // moment anything (the planned run-history screen in particular)
        // reads `run.plan` properties.
        let allRuns = (try? context.fetch(FetchDescriptor<Run>())) ?? []
        guard !allRuns.isEmpty else { return }

        let livePlanIDs = Set(((try? context.fetch(FetchDescriptor<Plan>())) ?? []).map(\.persistentModelID))
        for run in allRuns {
            let planIsLive = run.plan.map { livePlanIDs.contains($0.persistentModelID) } ?? false
            if !planIsLive {
                context.delete(run)
            }
        }
        try? context.save()
    }
}
