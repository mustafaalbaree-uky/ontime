import SwiftUI
import SwiftData

/// Three tabs, down from six. The four that went away — Plans, Routines,
/// Templates and the old standalone Countdowns — were four different
/// navigational answers to "make a sequence," and they exposed the
/// persistence schema (`TaskTemplate` → `Routine` → `Plan` → `Run`) as
/// navigation, so none of their labels meant anything until you already knew
/// the model. What's left is a screen for what you're doing now, a screen
/// for what's already running, and settings.
///
/// `Plan` still exists; it's just invisible. `RunLauncher` mints one per run
/// and no screen ever lists them.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NowView()
                .tabItem { Label("Now", systemImage: "timer") }

            CountdownsView()
                .tabItem { Label("Active", systemImage: "list.bullet.clipboard") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            resumeOpenRuns()
            armScheduledRoutines()
        }
        .onChange(of: scenePhase) { _, phase in
            // The opportunistic half of the arming model: any time the app
            // comes forward, catch up on routines whose window opened while
            // it wasn't running. Cheap and idempotent — `lastArmedDay` makes
            // a second call within the same day a no-op.
            guard phase == .active else { return }
            armScheduledRoutines()
        }
    }

    private func armScheduledRoutines() {
        ScheduleService.armDueRoutines(in: modelContext)
        ScheduleService.refreshArmAlarms(in: modelContext)
    }

    /// Runs used to only ever be driven by whichever `RunView` was on
    /// screen, so on every launch the only question was "is anything still
    /// open at all" — if not, any Live Activity left behind (app
    /// force-quit mid-run, nothing ran on the way out) was necessarily
    /// stale and got cleared. Now that a `Run` keeps going via its
    /// `RunEngine` independent of any view, and more than one can be open
    /// at once, "stale" instead means "an activity whose plan doesn't match
    /// any run we're about to resume" — so every open run gets its engine
    /// started back up (which also re-syncs its own Live Activity/
    /// notifications from wherever it actually is), and only activities
    /// left over with no matching run get torn down.
    private func resumeOpenRuns() {
        RunEngineStore.shared.configure(modelContext: modelContext)

        // `OnTimeApp.deleteOrphanedRuns` already ran, synchronously, before
        // this view (or any sibling tab) was constructed — a `Run` reaching
        // here is guaranteed to have a live `Plan`.
        let openRunDescriptor = FetchDescriptor<Run>(predicate: #Predicate { $0.finishedAt == nil })
        let openRuns = (try? modelContext.fetch(openRunDescriptor)) ?? []

        guard !openRuns.isEmpty else {
            Notifications.shared.cancelAllRunNotifications()
            Task { await LiveActivityManager.endAll() }
            return
        }

        var livePlanIds: Set<String> = []
        for run in openRuns {
            let engine = RunEngineStore.shared.engine(for: run)
            if let p = engine.plan { livePlanIds.insert("\(p.id)") }
        }
        Task {
            await LiveActivityManager.endOrphans(keeping: livePlanIds)
        }
    }
}

#Preview {
    RootView()
}
