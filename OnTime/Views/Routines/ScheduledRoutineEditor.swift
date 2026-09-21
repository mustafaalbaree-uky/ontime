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
    /// Asks the list to delete this routine once the sheet has gone. The
    /// editor never deletes it itself: this view is bound to the routine and
    /// keeps reading it through the dismiss animation, and a read of a model
    /// whose row has been saved away is the uncatchable "backing data could
    /// no longer be found" crash.
    var onDelete: () -> Void = {}

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
    @State private var confirmingDelete = false
    /// Set when the toggle was turned on and iOS said no, so the row can say
    /// why it went back off.
    @State private var alarmsDenied = false

    /// A real alarm at the routine's start time, see `StartAlarms`. Turning
    /// it on is the moment iOS asks for permission; a refusal turns it back
    /// off rather than leaving a switch on that rings nothing. The alarms
    /// themselves are set by the list's `refresh()` when this sheet closes,
    /// with every other consequence of an edit.
    private var startAlarmBinding: Binding<Bool> {
        Binding(
            get: { AppSettings.shared.wantsStartAlarm(routine.uuid) },
            set: { wants in
                AppSettings.shared.setWantsStartAlarm(wants, for: routine.uuid)
                guard wants else { alarmsDenied = false; return }
                Task {
                    let allowed = await StartAlarms.authorize()
                    alarmsDenied = !allowed
                    if !allowed { AppSettings.shared.setWantsStartAlarm(false, for: routine.uuid) }
                }
            }
        )
    }

    private var blocks: [Block] { routine.orderedBlocks }

    /// The longest lead that still leaves the whole routine inside the eight
    /// hours iOS lets one Live Activity live, with ten minutes to spare.
    /// Rounded down to the stepper's coarsest step, and never under the old
    /// ceiling, so a very long routine is not squeezed below what it had.
    private var maxLeadMinutes: Int {
        let routineMinutes = blocks
            .filter { !$0.kind.isOpenDuration }
            .reduce(0) { $0 + TravelTimeService.shared.manualEstimateMinutes(for: $1) }
        let room = 8 * 60 - 10 - routineMinutes
        return max(240, room / 30 * 30)
    }

    private var leadStep: Int {
        switch routine.armLeadMinutes {
        case ..<60: return 5
        case ..<240: return 15
        default: return 30
        }
    }

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

                    // The only other way to delete a routine is a swipe on
                    // the list, which nothing on screen hints at.
                    InkCard {
                        InkButtonRow(title: "Delete Routine", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
                .padding(.bottom, InkMetric.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .inkNavigation(title: routine.name.isEmpty ? "New routine" : routine.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .inkToolbarButton()
                }
            }
            .alert("Delete this routine?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $sheet) { route in
                switch route {
                case .anchorTime:
                    FullScreenTimePicker(title: "Be done by", date: anchorBinding)
                case .addStep:
                    QuickBlockEditorSheet(
                        existingBlock: nil,
                        owningRoutine: routine,
                        allowsOpenDuration: !blocks.contains { $0.kind.isOpenDuration }
                    ) {}
                case .editStep(let block):
                    QuickBlockEditorSheet(
                        existingBlock: block,
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

    /// The one number. Same thin numeral and place the composer gives Final
    /// Time, but in plain white: the composer's number is the only spectrum
    /// element in the product.
    private var anchorSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("Be done by")

            Button {
                sheet = .anchorTime
            } label: {
                Text(timeString(hour: routine.anchorHour, minute: routine.anchorMinute))
                    .onTimeNumeral(InkType.displaySize)
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
            SectionLabel("Days")

            WeekdayChips(weekdays: Binding(
                get: { routine.weekdays },
                set: { routine.weekdays = $0 }
            ))

            InkCard {
                // "Activates", the word the Scheduled list uses for the same
                // moment. This row said "Wakes up", so one event had two
                // names depending on the screen.
                // The ceiling was a flat 240, which is too short for a routine
                // he wants counting down from the evening before. The real
                // limit is iOS's: a Live Activity is ended by the system
                // eight hours after it starts, so the lead plus the routine
                // itself has to fit inside that, or the countdown is taken
                // down part way through the steps. The step widens with the
                // value, because 5 minutes at a time to seven hours is
                // eighty taps.
                InkStepperRow(title: "Activates", value: $routine.armLeadMinutes,
                              range: 5...maxLeadMinutes, step: leadStep,
                              format: { TimeFormatting.spanWords(TimeInterval($0 * 60)) })
                if StartAlarms.isSupported {
                    InkToggleRow(title: "Alarm at start", isOn: startAlarmBinding)
                }
                InkToggleRow(title: "Enabled", isOn: $routine.isEnabled)
            }

            if alarmsDenied {
                Text("Alarms are off for On Time in iOS Settings.")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.waiting)
            } else if AppSettings.shared.wantsStartAlarm(routine.uuid),
                      let occurrence = ScheduleService.nextOccurrence(for: routine) {
                Text("Rings at \(timeString(occurrence.mustStartAt)), through silent mode and Focus.")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            }

            // The stepper's number has no meaning without the two clock
            // times it sits between.
            if let occurrence = ScheduleService.nextOccurrence(for: routine) {
                Text("Activates \(timeString(occurrence.armAt)), \(TimeFormatting.spanWords(TimeInterval(routine.armLeadMinutes * 60))) before the \(timeString(occurrence.mustStartAt)) start.")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            }
            if routine.armLeadMinutes >= maxLeadMinutes {
                Text("iOS ends a Live Activity 8 hours after it starts.")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
            }
        }
    }

    private var sequenceSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel(text: "The sequence") {
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
                    let starts = stepStarts
                    // One card for the whole sequence, ruled between steps,
                    // the way the composer draws it.
                    InkCard {
                        ForEach(Array(blocks.enumerated()), id: \.element.uuid) { index, block in
                            Button {
                                sheet = .editStep(block)
                            } label: {
                                stepRow(block, startsAt: starts[block.uuid])
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

    private func stepRow(_ block: Block, startsAt: Date?) -> some View {
        StepRowCard(
            symbol: block.template?.symbol ?? block.kind.defaultSymbol,
            name: block.name,
            meta: metaLine(for: block, startsAt: startsAt),
            onDelete: { delete(block) }
        ) {
            if block.kind == .flex {
                badge("Flex")
            } else if block.kind == .walk {
                badge("Walk")
            } else {
                StepRowValue(text: "\(TravelTimeService.shared.manualEstimateMinutes(for: block)) min")
            }
        }
    }

    /// When each step begins on the next occurrence: `mustStartAt` plus
    /// everything before it, an open duration step counting as zero, which
    /// is how the occurrence itself was solved.
    private var stepStarts: [UUID: Date] {
        guard let occurrence = ScheduleService.nextOccurrence(for: routine) else { return [:] }
        var starts: [UUID: Date] = [:]
        var cursor = occurrence.mustStartAt
        for block in blocks {
            starts[block.uuid] = cursor
            guard !block.kind.isOpenDuration else { continue }
            let minutes = TravelTimeService.shared.manualEstimateMinutes(for: block)
            cursor = cursor.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return starts
    }

    /// Leads with the clock time the step begins, same as the composer's
    /// rows. It used to lead with "STEP 2", which the row's place already
    /// says.
    private func metaLine(for block: Block, startsAt: Date?) -> [String] {
        var parts: [String] = []
        if block.kind != .startAt, let startsAt {
            parts.append(timeString(startsAt))
        }
        if block.kind == .drive, let dest = block.destinationPlace {
            parts.append("to \(dest.name)")
        }
        return parts
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(InkType.value)
            .foregroundStyle(OnTimeSpectrum.tertiaryText)
    }

    /// Shown under the step list so the consequence of the durations above is
    /// visible while editing them, rather than only once the routine fires.
    private var startSummary: String? {
        guard let occurrence = ScheduleService.nextOccurrence(for: routine) else { return nil }
        guard !blocks.isEmpty else { return nil }
        return "Start by \(timeString(occurrence.mustStartAt))"
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
