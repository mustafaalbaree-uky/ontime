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
    @Query(sort: \ScheduledRoutine.anchorHour) private var routines: [ScheduledRoutine]

    @State private var editingRoutine: ScheduledRoutine?
    @State private var now = Date()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                if routines.isEmpty {
                    ContentUnavailableView(
                        "Nothing Scheduled",
                        systemImage: "repeat",
                        description: Text("A scheduled routine is something you do on the same days, by the same time, with the same steps before it. It wakes up on its own and starts counting down about an hour before you need to begin.")
                    )
                } else {
                    ForEach(routines) { routine in
                        Button {
                            editingRoutine = routine
                        } label: {
                            RoutineRow(routine: routine, now: now)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(routine)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                routine.skip(on: Date())
                                refresh()
                            } label: {
                                Label("Skip Today", systemImage: "moon.zzz")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Scheduled")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(ticker) { now = $0 }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let routine = ScheduledRoutine(name: "", anchorHour: 7, anchorMinute: 0)
                        modelContext.insert(routine)
                        editingRoutine = routine
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editingRoutine, onDismiss: refresh) { routine in
                ScheduledRoutineEditor(routine: routine)
            }
        }
    }

    /// Arm times move whenever a step's duration or the anchor changes, so
    /// the pending alarms have to be rebuilt after any edit.
    private func refresh() {
        ScheduleService.refreshArmAlarms(in: modelContext)
    }

    private func delete(_ routine: ScheduledRoutine) {
        modelContext.delete(routine)
        refresh()
    }
}

private struct RoutineRow: View {
    let routine: ScheduledRoutine
    let now: Date

    private var occurrence: ScheduleService.Occurrence? {
        ScheduleService.nextOccurrence(for: routine, now: now)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name.isEmpty ? "Untitled" : routine.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("\(timeString(hour: routine.anchorHour, minute: routine.anchorMinute)) • \(dayLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(statusLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }

            Spacer()

            Text("\(routine.orderedBlocks.count) step\(routine.orderedBlocks.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .opacity(routine.isEnabled ? 1 : 0.5)
    }

    private var statusLine: String {
        guard routine.isEnabled else { return "Off" }
        guard routine.orderedBlocks.isEmpty == false else { return "No steps yet" }
        guard let occurrence else { return "Not scheduled" }
        if routine.isSkipped(on: now) { return "Skipped today" }
        if occurrence.isArmed(at: now) { return "Active now" }
        return "Activates in \(relative(occurrence.armAt, from: now))"
    }

    private var statusColor: Color {
        guard routine.isEnabled, !routine.orderedBlocks.isEmpty else { return .secondary }
        guard let occurrence else { return .secondary }
        return occurrence.isArmed(at: now) ? .green : .secondary
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
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
