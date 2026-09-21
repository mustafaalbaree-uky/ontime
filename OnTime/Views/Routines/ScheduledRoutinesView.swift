import SwiftUI
import SwiftData

/// The "hidden menu" behind Now's top-right button: everything that runs on
/// its own, and when each one next wakes up.
///
/// Replaces the old Routines tab, which asked for a name *and* an "anchor
/// kind" (Manual Time vs. Mosque Iqama) before you could add a single step,
/// then dropped you into a separate editor to actually build the sequence.
/// Here a routine is a name, a time, and steps — the same three things the
/// Now screen already asks for, using the same step editor.
struct ScheduledRoutinesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    // Minute as the secondary key — hour alone listed 7:30 before 7:05
    // whenever SwiftData felt like it.
    @Query(sort: [SortDescriptor(\ScheduledRoutine.anchorHour), SortDescriptor(\ScheduledRoutine.anchorMinute)])
    private var routines: [ScheduledRoutine]

    /// One route, one `.sheet`: SwiftUI honours a single sheet presentation
    /// per view, so the time picker could not be a second modifier beside the
    /// editor's. A new sheet is a new case.
    private enum Sheet: Identifiable {
        case edit(ScheduledRoutine)
        case time(ScheduledRoutine)

        var id: String {
            switch self {
            case .edit(let routine): return "edit-\(routine.uuid.uuidString)"
            case .time(let routine): return "time-\(routine.uuid.uuidString)"
            }
        }
    }

    @State private var sheet: Sheet?
    /// The row the plus button just inserted, so an abandoned editor (no
    /// name, no steps, dismissed) deletes it instead of leaving a permanent
    /// "Untitled, 7:00 AM, every day" row per aborted attempt.
    @State private var draftRoutine: ScheduledRoutine?
    /// A routine the editor asked to have deleted, held until its sheet has
    /// gone. See `ScheduledRoutineEditor.onDelete`.
    @State private var pendingDelete: ScheduledRoutine?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                if routines.isEmpty {
                    InkEmpty("Nothing scheduled.")
                        .inkListRow()
                } else {
                    ForEach(routines) { routine in
                        // Start Now and Skip Today are on the card as well as
                        // behind the swipes. They were swipe only, and the
                        // person this app is for did not know either existed:
                        // he reported that a stopped routine "doesn't start
                        // counting down" again, which is what the hidden
                        // Start Now does.
                        RoutineRow(
                            routine: routine,
                            now: now,
                            onEdit: { sheet = .edit(routine) },
                            onChangeTime: { sheet = .time(routine) },
                            onStart: { startNow(routine) },
                            onSkip: {
                                routine.skip(on: Date())
                                refresh()
                            },
                            onUndoSkip: {
                                routine.unskip(on: Date())
                                refresh()
                            }
                        )
                        .inkListRow()
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(routine)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(OnTimeSpectrum.late)
                            Button {
                                routine.skip(on: Date())
                                refresh()
                            } label: {
                                Label("Skip Today", systemImage: "moon.zzz")
                            }
                            .tint(Color(white: 0.22))
                        }
                        // The way back from a cancelled run. Cancelling
                        // stamps `lastArmedDay`, so the routine is done for
                        // the day and used to be unreachable until tomorrow:
                        // the app had a Skip Today and no undo for it.
                        .swipeActions(edge: .leading) {
                            Button {
                                startNow(routine)
                            } label: {
                                Label("Start Now", systemImage: "play.fill")
                            }
                            .tint(OnTimeSpectrum.done)
                        }
                    }
                }
            }
            .inkList()
            .inkNavigation(title: "Scheduled")
            .onReceive(ticker) { now = $0 }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .inkToolbarButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let routine = ScheduledRoutine(name: "", anchorHour: 7, anchorMinute: 0)
                        modelContext.insert(routine)
                        draftRoutine = routine
                        sheet = .edit(routine)
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(OnTimeSpectrum.primaryText)
                    }
                }
            }
            .sheet(item: $sheet, onDismiss: {
                if let doomed = pendingDelete {
                    pendingDelete = nil
                    draftRoutine = nil
                    delete(doomed)
                    return
                }
                if let draft = draftRoutine {
                    draftRoutine = nil
                    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty && draft.orderedBlocks.isEmpty {
                        modelContext.delete(draft)
                    }
                }
                refresh()
            }) { route in
                switch route {
                case .edit(let routine):
                    ScheduledRoutineEditor(routine: routine) { pendingDelete = routine }
                case .time(let routine):
                    // An iqama time moves by a quarter of an hour a few times
                    // a year, and changing it meant opening the whole editor
                    // to reach the one number. The picker commits on Done
                    // only, and `onDismiss` above runs `refresh()` either way.
                    FullScreenTimePicker(title: "Be done by", date: anchorBinding(for: routine))
                }
            }
        }
    }

    /// Arm times move whenever a step's duration or the anchor changes, so
    /// the pending alarms have to be rebuilt after any edit — and so does
    /// the run this routine may already have armed. A routine's blocks are
    /// copies, so nothing about a live run tracked its routine before this:
    /// moving "be done by" from 12:50 to 1:10 while the countdown was
    /// running left the countdown working toward 12:50 with no sign the
    /// edit had landed anywhere.
    private func refresh() {
        ScheduleService.syncAllLiveRuns(in: modelContext)
        ScheduleService.refreshArmAlarms(in: modelContext)
        WidgetBridge.shared.setNeedsRefresh()
    }

    /// Starts the routine (or finds the run it already has) and leaves for
    /// its countdown. It used to stay on this list, where the only sign that
    /// anything had happened was one status line changing colour.
    ///
    /// The way to the run's page is the route a notification tap takes:
    /// `NowView` listens for `openRunNotification` and looks the run up again
    /// on the next runloop pass, which covers its query not having caught up
    /// with a run minted a moment ago.
    private func startNow(_ routine: ScheduledRoutine) {
        guard let run = ScheduleService.armNow(routine, in: modelContext) else {
            now = Date()
            return
        }
        var payload = ["routineId": routine.uuid.uuidString]
        if let planId = run.plan?.uuid.uuidString { payload["planId"] = planId }
        NotificationCenter.default.post(name: OnTimeShared.openRunNotification,
                                        object: nil, userInfo: payload)
        dismiss()
    }

    private func anchorBinding(for routine: ScheduledRoutine) -> Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = routine.anchorHour
                comps.minute = routine.anchorMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                routine.anchorHour = comps.hour ?? routine.anchorHour
                routine.anchorMinute = comps.minute ?? routine.anchorMinute
            }
        )
    }

    private func delete(_ routine: ScheduledRoutine) {
        // Through the cleanup helper, never a bare delete: spawned Plans
        // hold an unpaired `routine` pointer that would dangle and later
        // crash uncatchably — see `DeleteCleanup`.
        DeleteCleanup.delete(routine, in: modelContext)
        refresh()
    }
}

/// One routine as a card: the name and status open the editor, the time
/// opens the time picker, and the actions that fit its state sit along the
/// bottom edge.
///
/// It is several buttons rather than one button around the card, because a
/// button inside another button's label never receives its tap. Each one is
/// `.plain` styled, which is also what lets a `List` row hold more than one:
/// with the default style the row itself takes the tap and fires them all.
private struct RoutineRow: View {
    let routine: ScheduledRoutine
    let now: Date
    var onEdit: () -> Void
    var onChangeTime: () -> Void
    var onStart: () -> Void
    var onSkip: () -> Void
    var onUndoSkip: () -> Void

    private enum Action: Identifiable {
        case open, start, skip, undoSkip

        var id: Self { self }

        var title: String {
            switch self {
            case .open: return "Open"
            case .start: return "Start Now"
            case .skip: return "Skip Today"
            case .undoSkip: return "Undo Skip"
            }
        }
    }

    @Query(filter: #Predicate<Run> { $0.finishedAt == nil }) private var openRuns: [Run]

    private var occurrence: ScheduleService.Occurrence? {
        ScheduleService.nextOccurrence(for: routine, now: now)
    }

    private var hasOpenRun: Bool {
        openRuns.contains { $0.plan?.routine?.uuid == routine.uuid }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onEdit) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(routine.name.isEmpty ? "Untitled" : routine.name)
                            .font(InkType.rowTitle)
                            .foregroundStyle(OnTimeSpectrum.primaryText)

                        Text("\(dayLabel) · \(stepCountLabel)")
                            .font(InkType.rowMeta)
                            .foregroundStyle(OnTimeSpectrum.tertiaryText)

                        Text(statusLine)
                            .font(InkType.rowMeta)
                            .foregroundStyle(statusColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onChangeTime) {
                    Text(timeString(hour: routine.anchorHour, minute: routine.anchorMinute))
                        .font(InkType.value)
                        .monospacedDigit()
                        .foregroundStyle(OnTimeSpectrum.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        // A small control on a card, so the raised surface.
                        // It was an outlined box.
                        .background(OnTimeSpectrum.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: InkMetric.innerRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Be done by \(timeString(hour: routine.anchorHour, minute: routine.anchorMinute))")
                .accessibilityHint("Changes the time")
            }
            .padding(InkMetric.rowPadding)

            if !actions.isEmpty {
                Rectangle()
                    .fill(OnTimeSpectrum.rule)
                    .frame(height: 1)

                HStack(spacing: 0) {
                    ForEach(actions) { action in
                        if action != actions.first {
                            Rectangle()
                                .fill(OnTimeSpectrum.rule)
                                .frame(width: 1, height: 20)
                        }
                        Button {
                            perform(action)
                        } label: {
                            Text(action.title)
                                .font(InkType.buttonQuiet)
                                .foregroundStyle(OnTimeSpectrum.primaryText)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectrumCard()
        .opacity(routine.isEnabled ? 1 : 0.5)
    }

    /// What this routine can do from here, given where it is in its day.
    /// A routine that is off or has no steps can do nothing, so it gets no
    /// row at all rather than a row of dead buttons.
    private var actions: [Action] {
        guard routine.isEnabled, !routine.orderedBlocks.isEmpty else { return [] }
        // `armNow` hands back the open run rather than minting a second one,
        // so the same call is what opens it.
        if hasOpenRun { return [.open] }
        if routine.isSkipped(on: now) { return [.start, .undoSkip] }
        if isDone { return [.start] }
        // `skip(on:)` skips today's date. Offered only while the next
        // occurrence is today's: late in the evening, with tomorrow's up
        // next, it would mark the row "Skipped today" and skip nothing.
        if let occurrence, Calendar.current.isDateInToday(occurrence.deadline) {
            return [.start, .skip]
        }
        return [.start]
    }

    private func perform(_ action: Action) {
        switch action {
        case .open, .start: onStart()
        case .skip: onSkip()
        case .undoSkip: onUndoSkip()
        }
    }

    private var stepCountLabel: String {
        let count = routine.orderedBlocks.count
        return count == 1 ? "1 step" : "\(count) steps"
    }

    private var statusLine: String {
        guard routine.isEnabled else { return "Off" }
        guard routine.orderedBlocks.isEmpty == false else { return "No steps" }
        guard let occurrence else { return "Not scheduled" }
        if routine.isSkipped(on: now) { return "Skipped today" }
        if occurrence.isArmed(at: now) {
            // "Active now" was printed for an occurrence that had armed and
            // then been cancelled, so the row claimed a countdown was
            // running when there was nothing left to open. Start Now on
            // the card starts it again.
            if isDone { return "Already ran" }
            return "Active now"
        }
        return "Activates in \(relative(occurrence.armAt, from: now))"
    }

    /// Armed this occurrence already, with no run left open from it.
    private var isDone: Bool {
        guard let occurrence, hasOpenRun == false else { return false }
        return ScheduleService.hasArmed(routine, occurrence: occurrence)
    }

    private var statusColor: Color {
        guard routine.isEnabled, !routine.orderedBlocks.isEmpty else { return OnTimeSpectrum.tertiaryText }
        guard let occurrence else { return OnTimeSpectrum.tertiaryText }
        guard occurrence.isArmed(at: now) else { return OnTimeSpectrum.tertiaryText }
        return isDone ? OnTimeSpectrum.tertiaryText : OnTimeSpectrum.done
    }

    private var dayLabel: String {
        if routine.runsEveryDay { return "Every day" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return routine.weekdays.sorted()
            .compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
            .joined(separator: " ")
    }

    private func relative(_ date: Date, from reference: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(reference) / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    private func timeString(hour: Int, minute: Int) -> String {
        TimeFormatting.clockString(hour: hour, minute: minute)
    }
}
