import SwiftUI
import SwiftData

/// Name, one time, the days it runs, and the steps. Deliberately the same
/// shape as the Now screen — anchor time on top, sequence underneath — and
/// it uses `QuickBlockEditorSheet` for steps rather than a second step
/// editor, so there is exactly one place in the app that asks what a step is.
/// (There used to be four, with three different labels for `.flex` between
/// them.)
struct ScheduledRoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var routine: ScheduledRoutine

    @State private var showingAddStep = false
    @State private var editingBlock: Block?
    @State private var showingTimePicker = false

    private var blocks: [Block] { routine.orderedBlocks }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Evening at the masjid", text: $routine.name)
                }

                Section {
                    Button {
                        showingTimePicker = true
                    } label: {
                        HStack {
                            Text("Be done by")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(timeString(hour: routine.anchorHour, minute: routine.anchorMinute))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.tint)
                        }
                    }
                } header: {
                    Text("Anchor Time")
                } footer: {
                    Text("The one number. Everything else is worked out backwards from it — when this changes, this is the only thing you edit.")
                }

                Section("Days") {
                    WeekdayPicker(weekdays: Binding(
                        get: { routine.weekdays },
                        set: { routine.weekdays = $0 }
                    ))
                }

                Section {
                    Stepper("Wake up \(routine.armLeadMinutes) min early",
                            value: $routine.armLeadMinutes, in: 5...240, step: 5)
                    Toggle("Enabled", isOn: $routine.isEnabled)
                } footer: {
                    Text("How far ahead of your start time this shows up on its own. Counted from when you have to *start*, not from the anchor — an hour before the deadline could already be too late.")
                }

                Section {
                    if blocks.isEmpty {
                        Text("No steps yet. Add what you do before the anchor time, in the order you do it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(blocks) { block in
                            Button {
                                editingBlock = block
                            } label: {
                                StepRow(block: block)
                            }
                            .buttonStyle(.plain)
                        }
                        .onMove(perform: move)
                        .onDelete(perform: delete)
                    }

                    Button {
                        showingAddStep = true
                    } label: {
                        Label("Add Step", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    if let summary = startSummary {
                        Text(summary)
                    }
                }
            }
            .navigationTitle(routine.name.isEmpty ? "New Routine" : routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, .constant(.active))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.headline)
                }
            }
            .sheet(isPresented: $showingAddStep) {
                QuickBlockEditorSheet(
                    existingBlock: nil,
                    newBlockOrder: (blocks.map(\.order).max() ?? -1) + 1,
                    isFirstPosition: blocks.isEmpty,
                    owningRoutine: routine
                ) {}
            }
            .sheet(item: $editingBlock) { block in
                QuickBlockEditorSheet(
                    existingBlock: block,
                    newBlockOrder: 0,
                    isFirstPosition: block.order == (blocks.map(\.order).min() ?? block.order),
                    owningRoutine: routine
                ) {}
            }
            .sheet(isPresented: $showingTimePicker) {
                FullScreenTimePicker(title: "Be Done By", date: anchorBinding)
            }
        }
    }

    /// Shown under the step list so the consequence of the durations above is
    /// visible while editing them, rather than only once the routine fires.
    private var startSummary: String? {
        guard let occurrence = ScheduleService.nextOccurrence(for: routine) else { return nil }
        guard !blocks.isEmpty else { return nil }
        return "You'd need to start at \(timeString(occurrence.mustStartAt)), and this would wake up at \(timeString(occurrence.armAt))."
    }

    private var anchorBinding: Binding<Date> {
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

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = blocks
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, block) in reordered.enumerated() {
            block.order = index
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(blocks[index])
        }
        routine.renumber()
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func timeString(hour: Int, minute: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let date = Calendar.current.date(from: comps) ?? Date()
        return timeString(date)
    }
}

private struct StepRow: View {
    let block: Block

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: block.template?.symbol ?? block.kind.defaultSymbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.name)
                    .foregroundStyle(.primary)
                if block.kind == .drive, let dest = block.destinationPlace {
                    Text("to \(dest.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if block.kind == .flex {
                Text("FLEX")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            } else {
                Text("\(TravelTimeService.shared.manualEstimateMinutes(for: block)) min")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WeekdayPicker: View {
    @Binding var weekdays: Set<Int>

    private var symbols: [String] { Calendar.current.veryShortWeekdaySymbols }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let on = weekdays.contains(day)
                Button {
                    // Never let the set empty out — a routine with no days
                    // has no next occurrence, so it would silently vanish
                    // from the schedule with nothing on screen explaining
                    // why.
                    if on, weekdays.count > 1 {
                        weekdays.remove(day)
                    } else if !on {
                        weekdays.insert(day)
                    }
                } label: {
                    Text(symbols.indices.contains(day - 1) ? symbols[day - 1] : "?")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                        .foregroundStyle(on ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
