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

    @State private var editingRoutine: ScheduledRoutine?
    /// The row the plus button just inserted, so an abandoned editor (no
    /// name, no steps, dismissed) deletes it instead of leaving a permanent
    /// "Untitled, 7:00 AM, every day" row per aborted attempt.
    @State private var draftRoutine: ScheduledRoutine?
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
                        Button {
                            editingRoutine = routine
                        } label: {
                            RoutineRow(routine: routine, now: now)
                        }
                        .buttonStyle(.plain)
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
            .inkNavigation(title: "SCHEDULED")
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
                        editingRoutine = routine
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(OnTimeSpectrum.primaryText)
                    }
                }
            }
            .sheet(item: $editingRoutine, onDismiss: {
                if let draft = draftRoutine {
                    draftRoutine = nil
                    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty && draft.orderedBlocks.isEmpty {
                        modelContext.delete(draft)
                    }
                }
                refresh()
            }) { routine in
                ScheduledRoutineEditor(routine: routine)
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

    private func startNow(_ routine: ScheduledRoutine) {
        ScheduleService.armNow(routine, in: modelContext)
        now = Date()
    }

    private func delete(_ routine: ScheduledRoutine) {
        // Through the cleanup helper, never a bare delete: spawned Plans
        // hold an unpaired `routine` pointer that would dangle and later
        // crash uncatchably — see `DeleteCleanup`.
        DeleteCleanup.delete(routine, in: modelContext)
        refresh()
    }
}

private struct RoutineRow: View {
    let routine: ScheduledRoutine
    let now: Date

    @Query(filter: #Predicate<Run> { $0.finishedAt == nil }) private var openRuns: [Run]

    private var occurrence: ScheduleService.Occurrence? {
        ScheduleService.nextOccurrence(for: routine, now: now)
    }

    private var hasOpenRun: Bool {
        openRuns.contains { $0.plan?.routine?.uuid == routine.uuid }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name.isEmpty ? "Untitled" : routine.name)
                    .font(InkType.rowTitle)
                    .foregroundStyle(OnTimeSpectrum.primaryText)

                Text("\(timeString(hour: routine.anchorHour, minute: routine.anchorMinute)) · \(dayLabel)")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)

                Text(statusLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            Text("\(routine.orderedBlocks.count) step\(routine.orderedBlocks.count == 1 ? "" : "s")")
                .font(InkType.rowMeta)
                .foregroundStyle(OnTimeSpectrum.tertiaryText)
        }
        .padding(InkMetric.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectrumCard()
        .opacity(routine.isEnabled ? 1 : 0.5)
    }

    private var statusLine: String {
        guard routine.isEnabled else { return "Off" }
        guard routine.orderedBlocks.isEmpty == false else { return "No steps" }
        guard let occurrence else { return "Not scheduled" }
        if routine.isSkipped(on: now) { return "Skipped today" }
        if occurrence.isArmed(at: now) {
            // "Active now" was printed for an occurrence that had armed and
            // then been cancelled, so the row claimed a countdown was
            // running when there was nothing left to open. Swipe right to
            // start it again.
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
