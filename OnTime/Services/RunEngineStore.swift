import Foundation
import SwiftData

/// One `RunEngine` per open `Run`, keyed by the run's persisted `uuid`.
/// Whatever view is currently showing a `Run` just asks this store for its
/// engine instead of owning the tick/business logic itself — that's what
/// lets a run keep going after its screen is dismissed, and lets more than
/// one run be live at once for the Current Countdowns tab.
///
/// Keyed on `Run.uuid` rather than `persistentModelID` because a persistent
/// identifier is temporary until the first save: the temporary-to-permanent
/// transition after autosave made the same run miss its own engine lookup
/// and mint a second engine (two 1s timers driving the same rows).
@MainActor
@Observable
final class RunEngineStore {
    static let shared = RunEngineStore()

    private var modelContext: ModelContext?
    private(set) var engines: [UUID: RunEngine] = [:]

    private init() {
        // The Live Activity's "Complete Step" button and a notification's
        // "Next Step" action both used to post this with no run identity,
        // and the only listener was `RunView.onReceive` — a view that,
        // once a run keeps going after its screen is dismissed, is usually
        // not even mounted. Listening here instead means the tap works
        // regardless of what's on screen, routed to the right run by the
        // `planId` both callers now attach. (`OnTimeApp.init` touches this
        // singleton synchronously at launch so the observer exists before
        // the launch sequence can deliver anything.)
        NotificationCenter.default.addObserver(
            forName: OnTimeShared.advanceStepNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let planId = note.userInfo?["planId"] as? String else { return }
            Task { @MainActor in
                self?.advanceRun(planId: planId)
            }
        }
    }

    private func advanceRun(planId: String) {
        // The tap is being handled live; the persisted copy the intent
        // wrote for the dead-app case is now redundant.
        UserDefaults.standard.removeObject(forKey: OnTimeShared.pendingAdvanceKey)
        guard let engine = engines.values.first(where: { $0.plan?.uuid.uuidString == planId }) else { return }
        engine.advanceStep()
    }

    /// Consumes a "Complete Step" tap that arrived while no observer was
    /// alive — a `LiveActivityIntent` launching the app in the background
    /// posts to nobody, but it also persists the tap (see
    /// `CompleteStepIntent.perform`). Called from `RootView.resumeOpenRuns`
    /// once every open run's engine is back up.
    func consumePendingAdvance() {
        let defaults = UserDefaults.standard
        guard let record = defaults.dictionary(forKey: OnTimeShared.pendingAdvanceKey),
              let planId = record["planId"] as? String,
              let at = record["at"] as? TimeInterval else { return }
        defaults.removeObject(forKey: OnTimeShared.pendingAdvanceKey)
        guard Date().timeIntervalSince1970 - at <= OnTimeShared.pendingAdvanceMaxAge else { return }
        guard let engine = engines.values.first(where: { $0.plan?.uuid.uuidString == planId }) else { return }
        engine.advanceStep()
    }

    /// Must be called once, at launch, before any `register`/`engine(for:)`
    /// call — a singleton can't pull `@Environment(\.modelContext)` itself,
    /// so `OnTimeApp`/`RootView` hand it the same context every other view
    /// uses. Using a second, separate `ModelContext` here would leave two
    /// contexts mutating the same `Block` rows with no save coordination.
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Gets the engine for an already-known-open `Run`, creating (and
    /// starting) it if this is the first time anything has asked. Safe to
    /// call repeatedly — e.g. every time `RunView` appears for the same run.
    @discardableResult
    func engine(for run: Run) -> RunEngine {
        if let existing = engines[run.uuid] {
            existing.resume()
            return existing
        }
        // `OnTimeApp.init` configures this before any view exists; the
        // run's own context covers a run inserted elsewhere. If *neither*
        // exists the run was never inserted at all — the old fallback built
        // a second ModelContainer on the default store URL, which either
        // crashed on `try!` or silently split writes into a store nothing
        // else reads. Failing loudly is strictly better than either.
        guard let ctx = modelContext ?? run.modelContext else {
            fatalError("RunEngineStore.engine(for:) called before configure with an un-inserted Run")
        }
        let engine = RunEngine(run: run, modelContext: ctx)
        engines[run.uuid] = engine
        return engine
    }

    /// True cancellation of one run — ends its engine, Live Activity, and
    /// pending notifications, and removes it from the store. Distinct from
    /// a view just being dismissed, which leaves the engine registered and
    /// running.
    func cancel(_ run: Run) {
        if let engine = engines[run.uuid] {
            engine.cancel()
            engines.removeValue(forKey: run.uuid)
        } else {
            // No engine registered: tear down directly. Building a full
            // engine just to cancel it ran `resume()` first, whose enqueued
            // Live Activity start could race this cancellation's end and
            // leave a fresh activity for a dead run.
            run.finishedAt = Date()
            if let p = run.plan {
                Task { await LiveActivityManager.end(planId: p.uuid.uuidString) }
            }
        }
        if let p = run.plan {
            Notifications.shared.cancelRunNotifications(planId: p.uuid.uuidString)
            PiSchedule.clearRun(planId: p.uuid.uuidString)
        }
        WidgetBridge.shared.setNeedsRefresh()
    }

    /// Drops an engine once its run has finished normally (reached the last
    /// step). The engine calls this on itself from
    /// `syncLiveActivityAndNotifications`'s `isFinished` branch, so an
    /// unattended completion no longer waits for a `RunView` to appear;
    /// `RunView`'s finished screen also calls it, idempotently.
    func retire(_ run: Run) {
        engines[run.uuid]?.stopTicking()
        engines.removeValue(forKey: run.uuid)
        WidgetBridge.shared.setNeedsRefresh()
    }

    var openEngines: [RunEngine] {
        engines.values.filter { !$0.isFinished }
    }
}
