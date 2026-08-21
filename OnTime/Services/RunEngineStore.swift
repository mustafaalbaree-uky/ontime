import Foundation
import SwiftData

/// One `RunEngine` per open `Run`, keyed by the run's own persistent
/// identity. Whatever view is currently showing a `Run` just asks this
/// store for its engine instead of owning the tick/business logic itself —
/// that's what lets a run keep going after its screen is dismissed, and
/// lets more than one run be live at once for the Current Countdowns tab.
@MainActor
@Observable
final class RunEngineStore {
    static let shared = RunEngineStore()

    private var modelContext: ModelContext?
    private(set) var engines: [PersistentIdentifier: RunEngine] = [:]

    private init() {
        // The Live Activity's "Complete Step" button and a notification's
        // "Next Step" action both used to post this with no run identity,
        // and the only listener was `RunView.onReceive` — a view that,
        // once a run keeps going after its screen is dismissed, is usually
        // not even mounted. Listening here instead means the tap works
        // regardless of what's on screen, routed to the right run by the
        // `planId` both callers now attach.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("OnTimeAdvanceStepFromIntent"),
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
        guard let engine = engines.values.first(where: { $0.plan.map { "\($0.id)" } == planId }) else { return }
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
        if let existing = engines[run.persistentModelID] {
            existing.resume()
            return existing
        }
        // `RootView.resumeOpenRuns` configures this at launch before
        // anything else can call in, but a shipping crash on that ordering
        // if it's ever wrong is worse than just falling back to the
        // context `run` itself already belongs to — it was inserted into
        // one before any engine could be requested for it, at every call
        // site (`RunLauncher`).
        guard let ctx = modelContext ?? run.modelContext else {
            assertionFailure("RunEngineStore has no ModelContext to use — run was never inserted")
            let engine = RunEngine(run: run, modelContext: ModelContext(try! ModelContainer(for: Schema(Schema0.models))))
            engines[run.persistentModelID] = engine
            return engine
        }
        let engine = RunEngine(run: run, modelContext: ctx)
        engines[run.persistentModelID] = engine
        return engine
    }

    /// True cancellation of one run — ends its engine, Live Activity, and
    /// pending notifications, and removes it from the store. Distinct from
    /// a view just being dismissed, which leaves the engine registered and
    /// running.
    func cancel(_ run: Run) {
        let engine = engines[run.persistentModelID] ?? engine(for: run)
        engine.cancel()
        if let p = engine.plan {
            Notifications.shared.cancelRunNotifications(planId: "\(p.id)")
        }
        engines.removeValue(forKey: run.persistentModelID)
    }

    /// Drops an engine once its run has finished normally (reached the last
    /// step) — the engine already stopped its own ticking via
    /// `syncLiveActivityAndNotifications`'s `isFinished` branch; this just
    /// stops the store from holding a reference to it.
    func retire(_ run: Run) {
        engines[run.persistentModelID]?.stopTicking()
        engines.removeValue(forKey: run.persistentModelID)
    }

    var openEngines: [RunEngine] {
        engines.values.filter { !$0.isFinished }
    }
}
