import SwiftUI
import SwiftData

/// The one editor for a work session, used for three things that are the
/// same form: fixing a session you forgot to stop, correcting one you
/// clocked, and typing in a day you never started the timer for at all.
///
/// Values are held locally and written to the store only on Done, the same
/// commit on confirm rule `FullScreenTimePicker` follows, so Cancel and a
/// swipe down both actually cancel.
struct WorkSessionEditor: View {
    /// What is being edited. `.new` writes nothing until Done, so an
    /// abandoned manual entry leaves no row behind and there is no draft to
    /// clean up on dismiss.
    enum Target: Identifiable {
        case existing(WorkSession)
        case new(day: Date)

        var id: String {
            switch self {
            case .existing(let session): return session.uuid.uuidString
            case .new(let day): return "new-\(day.timeIntervalSince1970)"
            }
        }
    }

    let target: Target

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkSession.startedAt) private var allSessions: [WorkSession]

    @State private var start: Date
    @State private var end: Date
    @State private var isRunning: Bool
    @State private var note: String
    @State private var showingDeleteConfirmation = false

    init(target: Target) {
        self.target = target
        switch target {
        case .existing(let session):
            _start = State(initialValue: session.startedAt)
            // A session still running has no end to show, so the picker
            // opens at now: the overwhelmingly common edit here is "I
            // forgot to stop, it ended a while back," and now is the right
            // side of that to start scrubbing from.
            _end = State(initialValue: session.endedAt ?? Date())
            _isRunning = State(initialValue: session.isRunning)
            _note = State(initialValue: session.note)
        case .new(let day):
            // A remembered day opens at a plausible working span rather
            // than at midnight, which would take two long scrubs to fix
            // every single time.
            let calendar = Calendar.current
            let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            _start = State(initialValue: nine)
            _end = State(initialValue: calendar.date(byAdding: .hour, value: 8, to: nine) ?? nine)
            _isRunning = State(initialValue: false)
            _note = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InkMetric.section) {
                    VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
                        SectionLabel("START")
                        InkCard {
                            dateRow("Started", selection: $start)
                        }
                    }

                    VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
                        SectionLabel("END")
                        InkCard {
                            InkToggleRow(title: "Still running", isOn: $isRunning)
                                .disabled(isRunning == false && anotherSessionIsRunning)
                            if !isRunning {
                                dateRow("Ended", selection: $end)
                                if !durationSummary.isEmpty {
                                    InkTextLine(text: durationSummary)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
                        SectionLabel("NOTE")
                        InkCard {
                            InkTextRow(placeholder: "Note", text: $note, lineLimit: 1...3)
                        }
                    }

                    if let problem {
                        Text(problem)
                            .font(InkType.rowMeta)
                            .foregroundStyle(OnTimeSpectrum.waiting)
                    }

                    if case .existing = target {
                        InkCard {
                            InkButtonRow(title: "Delete session", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                        }
                    }
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
                .padding(.bottom, InkMetric.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .inkNavigation(title: isNew ? "ADD SESSION" : "EDIT SESSION")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .inkToolbarButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit() }
                        .inkToolbarButton()
                        .disabled(isInvalid)
                }
            }
            .confirmationDialog("Delete this session?",
                                isPresented: $showingDeleteConfirmation,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if case .existing(let session) = target {
                        WorkClock.delete(session, in: modelContext)
                    }
                    dismiss()
                }
            }
        }
    }

    /// A date plus a time, which is the one place the app still uses a system
    /// `DatePicker`: `FullScreenTimePicker` only knows clock times, and a work
    /// session needs the day as well.
    private func dateRow(_ title: String, selection: Binding<Date>) -> some View {
        InkRow {
            Text(title)
                .font(InkType.rowTitle)
                .foregroundStyle(OnTimeSpectrum.primaryText)
            Spacer(minLength: 8)
            DatePicker("", selection: selection,
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(OnTimeSpectrum.primaryText)
        }
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    /// Every other session, as intervals, for the overlap check. An open
    /// one is measured to now, which is the only honest reading of how much
    /// of the clock it currently claims.
    private var others: [WorkInterval] {
        let now = Date()
        return allSessions
            .filter { session in
                if case .existing(let edited) = target { return session.uuid != edited.uuid }
                return true
            }
            .map { $0.interval(now: now) }
    }

    private var anotherSessionIsRunning: Bool {
        allSessions.contains { session in
            guard session.isRunning else { return false }
            if case .existing(let edited) = target { return session.uuid != edited.uuid }
            return true
        }
    }

    private var editedInterval: WorkInterval {
        WorkInterval(start: start, end: isRunning ? max(start, Date()) : end)
    }

    private var isInvalid: Bool {
        if isRunning { return anotherSessionIsRunning }
        return end < start
    }

    /// Overlap is a warning, not a block: two sessions touching the same
    /// minute is usually a mistake, but only you know whether it is one,
    /// and refusing to save is a worse answer than saying so.
    private var problem: String? {
        if isRunning && anotherSessionIsRunning {
            return "Another session is running."
        }
        if !isRunning && end < start {
            return "End is before start."
        }
        if others.contains(where: { WorkHours.overlaps($0, editedInterval) }) {
            return "Overlaps another session."
        }
        return nil
    }

    private var durationSummary: String {
        guard end >= start else { return "" }
        return "\(WorkHours.clockString(editedInterval.seconds)) on the clock"
    }

    private func commit() {
        let session: WorkSession
        switch target {
        case .existing(let existing):
            session = existing
        case .new:
            let created = WorkSession(startedAt: start, wasEnteredManually: true)
            modelContext.insert(created)
            session = created
        }
        session.startedAt = start
        session.endedAt = isRunning ? nil : max(start, end)
        session.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try modelContext.save()
        } catch {
            print("WorkSessionEditor save failed: \(error)")
        }
        dismiss()
    }
}
