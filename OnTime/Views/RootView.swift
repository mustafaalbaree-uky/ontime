import SwiftUI
import SwiftData
import UIKit

/// Four tabs, down from six. The four that went away — Plans, Routines,
/// Templates and the old standalone Countdowns — were four different
/// navigational answers to "make a sequence," and they exposed the
/// persistence schema (`TaskTemplate` → `Routine` → `Plan` → `Run`) as
/// navigation, so none of their labels meant anything until you already knew
/// the model. What's left is a screen for what you're doing now, a screen
/// for what's already running, the work clock, and settings.
///
/// `Plan` still exists; it's just invisible. `RunLauncher` mints one per run
/// and no screen ever lists them.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// The system tab bar drawn in the app's own palette: black plate, a
    /// hairline on top, white for the tab you are on and white at 38% for the
    /// rest. Set through `UITabBarAppearance` because SwiftUI has no modifier
    /// for the unselected item's colour, and applied once here so no screen
    /// has to think about it.
    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.12)

        let selected = UIColor.white
        let unselected = UIColor.white.withAlphaComponent(0.38)
        for item in [appearance.stackedLayoutAppearance,
                     appearance.inlineLayoutAppearance,
                     appearance.compactInlineLayoutAppearance] {
            item.normal.iconColor = unselected
            item.normal.titleTextAttributes = [
                .foregroundColor: unselected,
                .font: UIFont.preferredFont(forTextStyle: .caption2)
            ]
            item.selected.iconColor = selected
            item.selected.titleTextAttributes = [
                .foregroundColor: selected,
                .font: UIFont.preferredFont(forTextStyle: .caption2)
            ]
        }

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView {
            NowView()
                .tabItem { Label("Now", systemImage: "timer") }

            CountdownsView()
                .tabItem { Label("Active", systemImage: "list.bullet.clipboard") }

            // The fourth tab, and not a violation of the no tab per model
            // rule above: this is not another way to build a sequence, it
            // is a separate thing you do, with a running state that has to
            // be visible without digging. Its `WorkSession` never touches
            // the Plan / Run machinery.
            WorkView()
                .tabItem { Label("Work", systemImage: "briefcase") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // Committed, not adaptive. The whole visual language is a spectrum
        // on true black (`OnTimeSpectrum`), which only reads as lit with
        // nothing behind it, and the Live Activity's plate is black at any
        // hour anyway — so a light appearance would make the phone and the
        // Lock Screen look like two different apps. Pinning the scheme also
        // means `.primary`/`.secondary` on the screens that still use them
        // resolve to white rather than near-black on an ink background.
        .preferredColorScheme(.dark)
        // The tint is for system controls that draw themselves in it, which
        // now means the toggles and nothing else: the tab bar wears the
        // appearance set above. NOT white. A white tint makes a `Toggle` fill
        // its on state track in white behind a white knob, so on and off
        // become the same pale capsule and every switch in Settings reads as
        // indistinguishable. See `OnTimeSpectrum.accent`.
        .tint(OnTimeSpectrum.accent)
        .task {
            resumeOpenRuns()
            armScheduledRoutines()
        }
        .onChange(of: scenePhase) { _, phase in
            // The opportunistic half of the arming model: any time the app
            // comes forward, catch up on routines whose window opened while
            // it wasn't running. Cheap and idempotent — `lastArmedDay` makes
            // a second call within the same day a no-op.
            // Backgrounding is the moment the widget is about to be looked
            // at, so the snapshot is written on the way out as well as on
            // the way in.
            guard phase == .active || phase == .background else { return }
            guard phase == .active else {
                WidgetBridge.shared.refresh()
                return
            }
            armScheduledRoutines()
        }
    }

    private func armScheduledRoutines() {
        ScheduleService.catchUp(in: modelContext)
        // Arming is where the Home Screen widget's picture changes most: a
        // routine stops being "upcoming" and becomes the live run.
        WidgetBridge.shared.setNeedsRefresh()
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
        WidgetBridge.shared.configure(modelContext: modelContext)

        // `OnTimeApp.deleteOrphanedRuns` already ran, synchronously, before
        // this view (or any sibling tab) was constructed — a `Run` reaching
        // here is guaranteed to have a live `Plan`.
        let openRunDescriptor = FetchDescriptor<Run>(predicate: #Predicate { $0.finishedAt == nil })
        let openRuns: [Run]
        do {
            openRuns = try modelContext.fetch(openRunDescriptor)
        } catch {
            // A failed fetch must NOT read as "no open runs" — that branch
            // tears down every Live Activity and pending notification for
            // runs that are still live in the store.
            print("resumeOpenRuns: fetch failed (\(error)); leaving activities and notifications alone")
            return
        }

        guard !openRuns.isEmpty else {
            Notifications.shared.cancelAllRunNotifications()
            Task { await LiveActivityManager.endAll() }
            RunEngineStore.shared.consumePendingAdvance()
            return
        }

        var livePlanIds: Set<String> = []
        for run in openRuns {
            let engine = RunEngineStore.shared.engine(for: run)
            if let p = engine.plan { livePlanIds.insert(p.uuid.uuidString) }
        }
        Task {
            await LiveActivityManager.endOrphans(keeping: livePlanIds)
        }
        // The same cleanup for notifications that `endOrphans` does for
        // activities. A force-quit leaves `scheduledIdentifiers` empty on
        // relaunch, so a previous session's step alerts for a run that is
        // over kept firing on schedule as long as *any* run was still open.
        Notifications.shared.cancelRunNotifications(exceptPlanIds: livePlanIds)
        // A Complete Step tap that arrived while the app was dead was
        // persisted by the intent; every engine is back up now, so it can
        // finally land on its run.
        RunEngineStore.shared.consumePendingAdvance()
    }
}

#Preview {
    RootView()
}
