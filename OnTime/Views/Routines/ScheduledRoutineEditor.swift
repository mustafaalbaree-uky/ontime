import SwiftUI
import SwiftData

/// Name, one time, the days it runs, and the steps. Deliberately the same
/// shape as the Now screen, anchor time on top and sequence underneath, and
/// it uses `QuickBlockEditorSheet` for steps rather than a second step
/// editor, so there is exactly one place in the app that asks what a step is.
/// (There used to be four, with three different labels for `.flex` between
/// them.)
struct ScheduledRoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var routine: ScheduledRoutine

    /// One route rather than three booleans and three stacked `.sheet`
    /// modifiers. SwiftUI honours a single sheet presentation per view, so
    /// stacking them meant only the last one could ever open, and tapping a
    /// step row or Add Step got the time picker instead. Same fix as
    /// `SequenceComposer.Sheet`, same reason.
    private enum Sheet: Identifiable {
        case anchorTime
        case addStep
        case editStep(Block)

        var id: String {
            switch self {
            case .anchorTime: return "anchorTime"
            case .addStep: return "addStep"
            case .editStep(let block): return "editStep-\(block.uuid.uuidString)"
            }
        }
    }

    @State private var sheet: Sheet?

    private var blocks: [Block] { routine.orderedBlocks }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InkMetric.section) {
                    InkCard {
                        InkTextRow(placeholder: "Name", text: $routine.name,
                                   autocapitalization: .sentences)
                    }

                    anchorSection
                    daysSection
                    sequenceSection
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
                .padding(.bottom, InkMetric.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .inkNavigation(title: routine.name.isEmpty ? "NEW ROUTINE" : routine.name.uppercased())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .inkToolbarButton()
                }
            }
            .sheet(item: $sheet) { route in
                switch route {
                case .anchorTime:
                    FullScreenTimePicker(title: "Be Done By", date: anchorBinding)
                case .addStep:
                    QuickBlockEditorSheet(
                        existingBlock: nil,
                        newBlockOrder: (blocks.map(\.order).max() ?? -1) + 1,
                        isFirstPosition: blocks.isEmpty,
                        owningRoutine: routine,
                        allowsOpenDuration: !blocks.contains { $0.kind.isOpenDuration }
                    ) {}
                case .editStep(let block):
                    QuickBlockEditorSheet(
                        existingBlock: block,
                        newBlockOrder: 0,
                        isFirstPosition: block.order == (blocks.map(\.order).min() ?? block.order),
                        owningRoutine: routine,
                        allowsOpenDuration: !blocks.contains {
                            $0.kind.isOpenDuration && $0.persistentModelID != block.persistentModelID
                        }
                    ) {}
                }
            }
        }
    }

    // MARK: - Sections

    /// The one number. Same weight and place the composer gives Final Time,
    /// but in plain white: the composer's number is the only spectrum
    /// element in the product.
    private var anchorSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("BE DONE BY")

            Button {
                sheet = .anchorTime
            } label: {
                Text(timeString(hour: routine.anchorHour, minute: routine.anchorMinute))
                    .font(InkType.display)
                    .monospacedDigit()
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
                    .spectrumCard()
            }
            .buttonStyle(.plain)
        }
    }

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("DAYS")

            WeekdayChips(weekdays: Binding(
                get: { routine.weekdays },
                set: { routine.weekdays = $0 }
            ))

            InkCard {
                InkStepperRow(title: "Wakes up", value: $routine.armLeadMinutes,
                              range: 5...240, step: 5, unit: "min")
                InkToggleRow(title: "Enabled", isOn: $routine.isEnabled)
            }
        }
    }

    private var sequenceSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel(text: "THE SEQUENCE") {
                HStack(spacing: 14) {
                    if blocks.count > 1 {
                        // Dragging a whole routine end to end, one row at a
                        // time, to fix having typed it in backwards is the
                        // kind of work a button should do.
                        Button {
                            reverseSteps()
                        } label: {
                            Label("Reverse", systemImage: "arrow.up.arrow.down")
                                .font(InkType.label)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(OnTimeSpectrum.primaryText)
                        }
                    }
                    PlusButton { sheet = .addStep }
                }
            }

            if blocks.isEmpty {
                InkEmpty("No steps.")
            } else {
                VStack(spacing: InkMetric.cardToCard) {
                    ForEach(Array(blocks.enumerated()), id: \.element.uuid) { index, block in
                        Button {
                            sheet = .editStep(block)
                        } label: {
                            stepRow(block, index: index)
                        }
                        .buttonStyle(.plain)
                        // Reordering by context menu rather than by a
                        // permanent drag grip: `editMode` kept every row in
                        // edit affordances even when nothing was being moved.
                        .contextMenu {
                            Button("Move Up") { move(index, by: -1) }
                                .disabled(index == 0)
                            Button("Move Down") { move(index, by: 1) }
                                .disabled(index == blocks.count - 1)
                            Button("Delete", role: .destructive) { delete(block) }
                        }
                    }

                    if let summary = startSummary {
                        InkCard {
                            InkTextLine(text: summary)
                        }
                    }
                }
            }
        }
    }

    private func stepRow(_ block: Block, index: Int) -> some View {
        StepRowCard(
            symbol: block.template?.symbol ?? block.kind.defaultSymbol,
            name: block.name,
            meta: metaLine(for: block, index: index),
            onDelete: { delete(block) }
        ) {
            if block.kind == .flex {
                badge("FLEX")
            } else if block.kind == .walk {
                badge("WALK")
            } else {
                StepRowValue(text: "\(TravelTimeService.shared.manualEstimateMinutes(for: block)) min")
            }
        }
    }

    private func metaLine(for block: Block, index: Int) -> [String] {
        var parts = ["STEP \(index + 1)"]
        if block.kind == .drive, let dest = block.destinationPlace {
            parts.append("to \(dest.name)")
        }
        return parts
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(InkType.label)
            .tracking(1.5)
            .foregroundStyle(OnTimeSpectrum.tertiaryText)
    }

    /// Shown under the step list so the consequence of the durations above is
    /// visible while editing them, rather than only once the routine fires.
    private var startSummary: String? {
        guard let occurrence = ScheduleService.nextOccurrence(for: routine) else { return nil }
        guard !blocks.isEmpty else { return nil }
        return "Start by \(timeString(occurrence.mustStartAt)) · Wakes up \(timeString(occurrence.armAt))"
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

    /// Moves one step one place. A Starts At step only means something as
    /// step 1: its duration is "time until the clock says X", which is
    /// meaningless behind other steps. So any startAt stays pinned to the
    /// front however the rest is shuffled.
    private func move(_ index: Int, by offset: Int) {
        var reordered = blocks
        let target = index + offset
        guard reordered.indices.contains(index), reordered.indices.contains(target) else { return }
        reordered.swapAt(index, target)
        let startAts = reordered.filter { $0.kind == .startAt }
        let rest = reordered.filter { $0.kind != .startAt }
        withAnimation {
            for (i, block) in (startAts + rest).enumerated() {
                block.order = i
            }
        }
    }

    /// Flips the whole sequence end to end. Goes through the same startAt
    /// pinning rule as `move`.
    private func reverseSteps() {
        let reversed = Array(blocks.reversed())
        let startAts = reversed.filter { $0.kind == .startAt }
        let rest = reversed.filter { $0.kind != .startAt }
        withAnimation {
            for (index, block) in (startAts + rest).enumerated() {
                block.order = index
            }
        }
    }

    private func delete(_ block: Block) {
        modelContext.delete(block)
        routine.renumber()
    }

    private func timeString(_ date: Date) -> String {
        TimeFormatting.clockString(date)
    }

    private func timeString(hour: Int, minute: Int) -> String {
        TimeFormatting.clockString(hour: hour, minute: minute)
    }
}
