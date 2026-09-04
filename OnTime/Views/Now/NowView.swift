import SwiftUI
import SwiftData
import UIKit

/// The front screen, and now the *only* screen you need during a run.
///
/// Now is a pager, in the shape the iPhone Home Screen uses: one page per
/// open run, the sequence composer as the last page, and a row of dots when
/// there is more than one page (and deliberately nothing when there is only
/// one, because a single dot is a control that says nothing).
///
/// What this replaces: a manually started run appeared only inside a
/// full-screen cover, so pressing Close left it running with no sign of it
/// anywhere on the front screen. Finding it again meant knowing to switch to
/// the Active tab and reading a one-line list row — subtle enough that it
/// did not read as "this is happening right now" at all. An armed *routine*
/// got a banner here; a run you started yourself got nothing. Now every open
/// run is a page, the app opens on the run you are actually in the middle
/// of, and swiping between two concurrent runs is one gesture.
///
/// The composer half is unchanged in what it does: the sequence here is real
/// `Block`s (`plan == nil && routine == nil` — "scratch" blocks, claimed by
/// a `Plan` the moment a run starts), the same type `ScheduledRoutineEditor`
/// uses, built through `QuickBlockEditorSheet` and started through
/// `RunLauncher`.
///
/// Two deliberate departures from the HTML prototype, both per explicit
/// product direction rather than oversight:
/// - The deadline is a plain time field. No automatic prayer-time lookup.
/// - Shortcut chips are entirely user-defined (`QuickShortcut`); nothing is
///   pre-seeded, unlike the prototype's hardcoded FAJR/ISHA/9AM.
struct NowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(filter: #Predicate<Run> { $0.finishedAt == nil }, sort: \Run.startedAt)
    private var openRuns: [Run]

    private var settings: AppSettings { .shared }

    /// Which page the pager is on. Run pages occupy `0..<openRuns.count`;
    /// the composer is always the last page.
    @State private var page = 0
    /// Presents the full run screen (step editing, walk card) over the pager.
    @State private var fullRun: Run?
    /// Which sheet the composer is asking for. It lives here, and is
    /// presented here, because a `.sheet` attached to a view *inside* a paged
    /// `TabView` does not reliably present — the page host tears the
    /// presentation down as it lays out. `fullRun` below has always worked
    /// for exactly this reason: it hangs outside the pager. See
    /// `ComposerRoute`.
    @State private var composerRoute: ComposerRoute?
    /// A run we have been asked to show but which `openRuns` has not caught
    /// up with yet. Cleared the moment it resolves. See `goTo(runId:)`.
    @State private var pendingRunId: UUID?

    private var composerIndex: Int { openRuns.count }
    private var pageCount: Int { openRuns.count + 1 }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            TabView(selection: $page) {
                ForEach(Array(openRuns.enumerated()), id: \.element.uuid) { index, run in
                    LiveRunPage(run: run) { fullRun = $0 }
                        .tag(index)
                }

                SequenceComposer(
                    onStarted: { run in
                        // Navigate to the run *by identity*, never by
                        // arithmetic on `openRuns.count`.
                        //
                        // This used to be `page = openRuns.count`, which is
                        // a race: `RunLauncher` has just inserted the run,
                        // and whether the `@Query` behind `openRuns` has
                        // refreshed by the time this closure runs is not
                        // something the caller can know. Refreshed, the
                        // count includes the new run and the expression
                        // lands on the composer; stale, it lands on the run.
                        // Both readings are one page apart, which is exactly
                        // the "sometimes it slides over and sometimes it
                        // doesn't" behaviour. Recording the uuid and
                        // resolving it whenever the query does catch up is
                        // deterministic either way.
                        goTo(runId: run.uuid)
                    },
                    onOpenRun: { run in
                        guard let index = openRuns.firstIndex(where: { $0.uuid == run.uuid }) else { return }
                        withAnimation(.easeInOut) { page = index }
                    },
                    route: $composerRoute
                )
                .tag(composerIndex)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .spectrumBackground()
        .fullScreenCover(item: $fullRun) { run in
            RunView(run: run)
        }
        // Presented from out here, outside the `TabView`, for the reason on
        // `composerRoute`. The composer only sets the value.
        .sheet(item: $composerRoute) { route in
            switch route {
            case .finalTime:
                FullScreenTimePicker(title: "Final Time", date: quickDeadlineBinding)
            case .scheduled:
                ScheduledRoutinesView()
            case .addShortcut(let initialTime):
                AddShortcutSheet(initialTime: initialTime)
            case .addStep(let order, let isFirst, let allowsOpenDuration):
                QuickBlockEditorSheet(
                    existingBlock: nil,
                    newBlockOrder: order,
                    isFirstPosition: isFirst,
                    allowsOpenDuration: allowsOpenDuration
                ) {}
            case .editStep(let block, let isFirst, let allowsOpenDuration):
                QuickBlockEditorSheet(
                    existingBlock: block,
                    newBlockOrder: 0,
                    isFirstPosition: isFirst,
                    allowsOpenDuration: allowsOpenDuration
                ) {}
            }
        }
        .onAppear {
            // Open on the run in progress, not on the builder. If nothing is
            // running there is only the builder to open on.
            if page >= pageCount { page = composerIndex }
            if !openRuns.isEmpty && page == composerIndex { page = 0 }
            syncVisiblePlan()
        }
        .onChange(of: openRuns.map(\.uuid)) { _, _ in
            // The query caught up. If a start was waiting on it, land now.
            resolvePendingRun()
        }
        .onChange(of: openRuns.count) { _, newCount in
            // A run finishing or being stopped removes a page out from under
            // the pager; clamping keeps the selection on something real
            // rather than leaving `page` pointing past the end, which lands
            // on a blank pane.
            if page > newCount { page = newCount }
            syncVisiblePlan()
        }
        .onChange(of: page) { _, _ in syncVisiblePlan() }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app means nothing is on screen, so the suppression
            // has to lift or the run you were last looking at stays silent
            // in your pocket.
            if phase == .active { syncVisiblePlan() } else { Notifications.shared.visiblePlanId = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: OnTimeShared.openRunNotification)) { note in
            openRun(from: note)
        }
    }

    /// The quick deadline's stored hour/minute as a `Date`, for the picker.
    /// Lives here as well as in the composer because the picker is presented
    /// from here now; both read and write the same two `AppSettings` fields,
    /// so there is still one stored value.
    private var quickDeadlineBinding: Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = AppSettings.shared.quickDeadlineHour
                comps.minute = AppSettings.shared.quickDeadlineMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                AppSettings.shared.quickDeadlineHour = comps.hour ?? AppSettings.shared.quickDeadlineHour
                AppSettings.shared.quickDeadlineMinute = comps.minute ?? AppSettings.shared.quickDeadlineMinute
            }
        )
    }

    // MARK: - Chrome

    private var topBar: some View {
        TopBar {
            leadingLabel
        } center: {
            SpectrumPageDots(count: pageCount, index: min(page, pageCount - 1))
        } trailing: {
            // Balances the leading label so the dots stay centred.
            leadingLabel
                .opacity(0)
                .accessibilityHidden(true)
        }
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    /// On the composer, with something running, this says *where* the running
    /// sequences are: to the left, with an arrow, and a count.
    ///
    /// The dots alone do not answer that. They say there is another page and
    /// which one you are on, but a run that has just started is a page you
    /// have never seen, and "swipe somewhere to find it" is not navigation.
    /// It is also a button, so the answer to "where did my run go" does not
    /// have to be a gesture.
    @ViewBuilder
    private var leadingLabel: some View {
        if page == composerIndex && !openRuns.isEmpty {
            Button {
                withAnimation(.easeInOut) { page = max(composerIndex - 1, 0) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(openRuns.count == 1 ? "1 RUNNING" : "\(openRuns.count) RUNNING")
                }
                .font(InkType.label)
                .tracking(1.5)
                .foregroundStyle(OnTimeSpectrum.primaryText)
            }
            .buttonStyle(.plain)
        } else {
            Text(page == composerIndex ? "NOW" : "RUNNING")
                .font(InkType.label)
                .tracking(2)
                .foregroundStyle(OnTimeSpectrum.secondaryText)
                .contentTransition(.opacity)
        }
    }

    // MARK: - Routing

    /// Slides the pager onto a specific run, now if the query already knows
    /// about it and as soon as it does otherwise.
    ///
    /// Also fires a success haptic, because sliding is not by itself a
    /// confirmation that Start worked: the run page can arrive looking a lot
    /// like the composer did, and if the pager happens to already be on the
    /// right index nothing visibly moves at all. A tap that starts something
    /// should be felt.
    private func goTo(runId: UUID) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        pendingRunId = runId
        resolvePendingRun()
    }

    private func resolvePendingRun() {
        guard let pendingRunId,
              let index = openRuns.firstIndex(where: { $0.uuid == pendingRunId }) else { return }
        self.pendingRunId = nil
        withAnimation(.easeInOut) { page = index }
    }

    /// Suppresses notifications for whichever plan is on screen. See
    /// `Notifications.visiblePlanId`.
    private func syncVisiblePlan() {
        guard openRuns.indices.contains(page) else {
            Notifications.shared.visiblePlanId = nil
            return
        }
        Notifications.shared.visiblePlanId = openRuns[page].plan?.uuid.uuidString
    }

    /// A notification tap asked for a specific run. A `planId` names a run
    /// that already exists; a `routineId` may name one that
    /// `ScheduleService.catchUp` is arming on this very foreground, so the
    /// lookup runs again on the next runloop pass before giving up.
    private func openRun(from note: Notification) {
        let planId = note.userInfo?["planId"] as? String
        let routineId = note.userInfo?["routineId"] as? String

        func locate() -> Int? {
            openRuns.firstIndex { run in
                if let planId, run.plan?.uuid.uuidString == planId { return true }
                if let routineId, run.plan?.routine?.uuid.uuidString == routineId { return true }
                return false
            }
        }

        if let index = locate() {
            withAnimation(.easeInOut) { page = index }
            return
        }
        DispatchQueue.main.async {
            if let index = locate() {
                withAnimation(.easeInOut) { page = index }
            } else if !openRuns.isEmpty {
                // The routine armed but the query has not caught up, or the
                // notification outlived its run. Showing *a* running
                // sequence beats showing the builder, which is the one
                // screen that definitely is not what was tapped.
                withAnimation(.easeInOut) { page = 0 }
            }
        }
    }
}

#Preview {
    NowView()
}
