import SwiftUI
import SwiftData

/// The sheets the composer can ask for, as one value — and deliberately
/// *asked for* rather than presented, because the composer cannot present a
/// sheet at all.
///
/// It is a page of `NowView`'s paged `TabView`, and a `.sheet` attached to a
/// view inside one of those pages does not reliably present: the page host
/// tears the presentation down as it lays its pages out, which the composer
/// provokes every second because its clock tick recomputes the body. From
/// the outside this is indistinguishable from a dead button — "+" and
/// "Scheduled" set their state correctly and nothing appeared.
///
/// The proof it is the *location* and not the modifier is already in this
/// screen: `NowView.fullScreenCover` hangs outside the `TabView` and the
/// Steps button it drives has always worked, while every presentation
/// attached inside a page has not. So the route travels up to `NowView` and
/// is presented there, out of the pager's reach.
///
/// (It was, before that, five separate `.sheet` modifiers stacked on this one
/// view, which is its own bug: SwiftUI honours one sheet per view, so only
/// the last could ever open. That is fixed too, but it was not the whole
/// story.)
///
/// Each case carries whatever the sheet needs, computed here at the moment
/// of the tap, so `NowView` needs none of this screen's queries to build it.
enum ComposerRoute: Identifiable {
    case finalTime
    case scheduled
    case addShortcut(initialTime: Date)
    case addStep(allowsOpenDuration: Bool)
    case editStep(block: Block, allowsOpenDuration: Bool)

    var id: String {
        switch self {
        case .finalTime: return "finalTime"
        case .scheduled: return "scheduled"
        case .addShortcut: return "addShortcut"
        case .addStep: return "addStep"
        case .editStep(let block, _): return "editStep-\(block.uuid.uuidString)"
        }
    }
}

/// The build-a-sequence half of the Now screen: pick a final time, stack up
/// steps, press Start. Lifted out of `NowView` when Now became a pager, so
/// the composer is one page among the runs rather than the whole screen.
///
/// The sequence here is real `Block`s with `plan == nil && routine == nil`
/// ("scratch" blocks). They persist, so a half-built sequence survives
/// closing the app, and Start runs copies of them, so it survives Start too.
struct SequenceComposer: View {
    /// Called once a `Run` exists, so the pager can slide onto it.
    var onStarted: (Run) -> Void
    /// Called when the armed-routine banner is tapped: the run already has a
    /// page of its own, so this scrolls to it rather than pushing a cover.
    var onOpenRun: (Run) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \QuickShortcut.order) private var shortcuts: [QuickShortcut]
    @Query(filter: #Predicate<Block> { $0.plan == nil && $0.routine == nil }, sort: \Block.order)
    private var scratchBlocks: [Block]

    private var settings: AppSettings { .shared }
    private var locationService: LocationService { .shared }
    private var travelService: TravelTimeService { .shared }

    @State private var now = Date()
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Which sheet this screen is asking for. Owned by `NowView`, not here —
    /// see `ComposerRoute`.
    @Binding var route: ComposerRoute?

    /// An `.alert`, for the reason on `LiveRunPage`'s Stop confirmation: this
    /// is a page of the pager, where an action sheet swallows its first tap.
    @State private var confirmingClear = false

    // MARK: - Derived time

    /// Resolved fresh from the stored hour/minute on every tick, so the
    /// deadline rolls to tomorrow on its own the moment it passes — see
    /// `DeadlineResolver`. Only the deadline rolls; a start time already in
    /// the past just means the plan is late, not that it's for tomorrow.
    private var deadline: Date {
        DeadlineResolver.resolve(hour: settings.quickDeadlineHour, minute: settings.quickDeadlineMinute,
                                 now: now, calendar: .current)
    }

    /// The latest possible start: deadline minus every known duration, the
    /// deadline itself when there are no steps yet. An open duration step
    /// contributes *zero* — mapping it to `.flex` here made the solve
    /// underdetermined (no start is given on this screen), the `try?`
    /// swallowed the error, and the headline countdown silently fell back to
    /// the bare deadline, overstating the time available by the sum of every
    /// fixed and drive step.
    private var mustStartAt: Date { solution?.start ?? deadline }

    /// The one solve behind both the headline and the clock time on each
    /// row, so the two cannot disagree. nil with no steps.
    private var solution: Solution? {
        guard !scratchBlocks.isEmpty else { return nil }
        let durations: [BlockDuration] = scratchBlocks.map { block in
            if block.kind.isOpenDuration { return .known(0) }
            let minutes = TravelTimeService.shared.manualEstimateMinutes(for: block)
            return .known(TimeInterval(minutes * 60))
        }
        let input = SolverInput(durations: durations, deadline: deadline, start: nil, pinnedFlex: nil)
        return try? Solver.solve(input)
    }

    private var remaining: TimeInterval { mustStartAt.timeIntervalSince(now) }

    /// Whether a (new or edited) step may still choose an open duration
    /// kind: at most one flex or walk block per plan is solvable, and the
    /// editor is the right place to stop the second one, not a silent nil
    /// solution later.
    private func allowsOpenDuration(excluding block: Block? = nil) -> Bool {
        !scratchBlocks.contains {
            $0.kind.isOpenDuration && $0.persistentModelID != block?.persistentModelID
        }
    }

    /// Which way the list runs, top to bottom.
    ///
    /// The app's original answer was fixed: last step first, on the argument
    /// that Final Time sits at the top of the screen so the step running
    /// just before it belongs directly underneath, leaving the step you'd
    /// actually start on next to the Start button. That is a real argument
    /// and it is also exactly backwards if you think forwards, which is what
    /// building a sequence feels like. It is a preference, so it is a switch
    /// (`AppSettings.sequenceNewestFirst`, in Settings) rather than a
    /// decision made once on someone's behalf. `scratchBlocks` itself stays
    /// in chronological order for the solver and `RunLauncher`, which both
    /// need that, not the display order.
    private var displayBlocks: [Block] {
        settings.sequenceNewestFirst ? Array(scratchBlocks.reversed()) : scratchBlocks
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArmedRoutineBanner(now: now) { onOpenRun($0) }
                header
                sequenceSection
                if settings.developerModeEnabled {
                    developerPanel
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .onReceive(timer) { date in
            // The tab view keeps this screen alive behind sheets and other
            // tabs; skipping the tick while the scene is inactive at least
            // stops the per-second body recompute when nothing is visible.
            guard scenePhase == .active else { return }
            now = date
        }
        .onAppear {
            locationService.requestLocation()
            refreshDriveEstimates()
        }
        .onChange(of: scratchBlocks) { _, _ in refreshDriveEstimates() }
        .alert("Clear the sequence?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { clearSequence() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(scratchBlocks.count == 1 ? "Removes 1 step." : "Removes \(scratchBlocks.count) steps.")
        }
        // No `.sheet` here, deliberately. `NowView` presents them, from
        // outside the pager. See `ComposerRoute`.
    }

    /// Fires a live MapKit ETA lookup for every drive step currently on the
    /// board, so a drive's minutes are real before a run starts rather than
    /// only after.
    private func refreshDriveEstimates() {
        let driveBlocks = scratchBlocks.filter { $0.kind == .drive }
        guard !driveBlocks.isEmpty else { return }
        Task {
            for block in driveBlocks {
                await travelService.resolve(block: block, departingAt: Date())
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Final time") {
                // Everything that runs on its own lives behind here, so this
                // screen stays about the thing in front of you.
                Button {
                    route = .scheduled
                } label: {
                    Label("Scheduled", systemImage: "repeat")
                        .font(InkType.label)
                        .foregroundStyle(OnTimeSpectrum.primaryText)
                }
            }

            Button {
                route = .finalTime
            } label: {
                SpectrumText(
                    text: timeString(deadlineTimeBinding.wrappedValue),
                    size: InkType.displaySize
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 18)
                .spectrumCard()
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shortcuts) { shortcut in
                        Button {
                            settings.quickDeadlineHour = shortcut.hour
                            settings.quickDeadlineMinute = shortcut.minute
                        } label: {
                            Chip(text: "\(shortcut.name) \(timeString(hour: shortcut.hour, minute: shortcut.minute))")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(shortcut) }
                        }
                    }

                    Button {
                        route = .addShortcut(initialTime: deadlineTimeBinding.wrappedValue)
                    } label: {
                        Chip(text: "Add", systemImage: "plus", style: .quiet)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var deadlineTimeBinding: Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = settings.quickDeadlineHour
                comps.minute = settings.quickDeadlineMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newValue in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                settings.quickDeadlineHour = comps.hour ?? settings.quickDeadlineHour
                settings.quickDeadlineMinute = comps.minute ?? settings.quickDeadlineMinute
            }
        )
    }

    // MARK: - Sequence

    private var sequenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "The sequence") {
                HStack(spacing: 14) {
                    if scratchBlocks.count > 1 {
                        // One tap to fix a sequence entered back to front. The
                        // alternative was deleting every step and re-adding them
                        // in the other order, because nothing in this screen has
                        // ever let you move a step.
                        Button {
                            reverseSequence()
                        } label: {
                            Label("Reverse", systemImage: "arrow.up.arrow.down")
                                .font(InkType.label)
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(OnTimeSpectrum.primaryText)
                        }
                    }

                    if !scratchBlocks.isEmpty {
                        // Start runs copies and leaves these steps where they
                        // are, so there has to be a way to empty the builder
                        // that is not deleting the rows one at a time.
                        Button("Clear") { confirmingClear = true }
                            .font(InkType.label)
                            .foregroundStyle(OnTimeSpectrum.primaryText)
                    }

                    PlusButton {
                        route = .addStep(allowsOpenDuration: allowsOpenDuration())
                    }
                }
            }

            if scratchBlocks.isEmpty {
                InkEmpty("No steps.")
            } else {
                // Solved once for the whole list, not once per row: this body
                // recomputes every second.
                let starts = stepStarts
                // One card for the whole sequence, ruled between steps. Each
                // step used to be an outlined card of its own.
                InkCard {
                    ForEach(displayBlocks) { block in
                        Button {
                            route = .editStep(block: block, allowsOpenDuration: allowsOpenDuration(excluding: block))
                        } label: {
                            blockRow(block, startsAt: starts[block.uuid])
                        }
                        .buttonStyle(.plain)
                        // The quick way to move a step, same menu the routine
                        // editor has. The way that can be found without knowing
                        // to hold a row down is the Position stepper in the step
                        // editor, which a tap on the row opens.
                        .contextMenu {
                            Button("Move Up") { move(block, by: -1) }
                                .disabled(block.uuid == displayBlocks.first?.uuid)
                            Button("Move Down") { move(block, by: 1) }
                                .disabled(block.uuid == displayBlocks.last?.uuid)
                            Button("Delete", role: .destructive) { delete(block) }
                        }
                    }
                }
            }
        }
    }

    /// When each step begins if the first one starts at `mustStartAt`. The
    /// solver's blocks come back in the order the durations went in, which
    /// is `scratchBlocks`' order.
    private var stepStarts: [UUID: Date] {
        guard let solution, solution.blocks.count == scratchBlocks.count else { return [:] }
        var starts: [UUID: Date] = [:]
        for (block, schedule) in zip(scratchBlocks, solution.blocks) {
            starts[block.uuid] = schedule.scheduledStart
        }
        return starts
    }

    private func blockRow(_ block: Block, startsAt: Date?) -> some View {
        StepRowCard(
            symbol: symbol(for: block),
            name: block.name,
            meta: meta(for: block, startsAt: startsAt),
            problem: block.kind == .drive ? travelService.error(for: block) : nil,
            onDelete: { delete(block) }
        ) {
            if block.kind == .flex {
                badge("Flex")
            } else if block.kind == .walk {
                badge("Walk")
            } else if block.kind == .drive {
                StepRowValue(text: "\(TravelTimeService.shared.manualEstimateMinutes(for: block)) min",
                             caption: driveSourceLabel(for: block),
                             captionColor: driveSourceColor(for: block))
            } else {
                StepRowValue(text: "\(TravelTimeService.shared.manualEstimateMinutes(for: block)) min")
            }
        }
    }

    /// The step's meta line. Joined by a middle dot inside `StepRowCard`.
    ///
    /// It leads with the clock time the step begins. It used to lead with
    /// "STEP 2", which the row's place in the list already says. A Wait until
    /// step has no start of its own to show: it runs from whenever the run
    /// starts until its clock time, and that time is already on the line.
    private func meta(for block: Block, startsAt: Date?) -> [String] {
        var parts: [String] = []
        if block.kind != .startAt, let startsAt {
            parts.append(timeString(startsAt))
        }
        if block.kind == .drive, let dest = block.destinationPlace {
            parts.append("to \(dest.name)")
        }
        if block.kind == .startAt, let hour = block.targetHour, let minute = block.targetMinute {
            parts.append("at \(timeString(hour: hour, minute: minute))")
        }
        if !block.isOpenEnded {
            parts.append("waits for tap")
        }
        return parts
    }

    /// A kind is not a state, so it is not coloured. Flex used to be amber
    /// and Walk green, which are the two colours this app spends on a solver
    /// problem and on something being finished.
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(InkType.value)
            .foregroundStyle(OnTimeSpectrum.tertiaryText)
    }

    // MARK: - Developer panel

    /// `AppSettings.developerModeEnabled`-gated debug view — GPS fix state,
    /// and per drive-block which tier (`live`/`cached`/`manual`) actually
    /// answered and why.
    private var developerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer mode")
                .font(InkType.label)
                .foregroundStyle(OnTimeSpectrum.waiting)

            VStack(alignment: .leading, spacing: 6) {
                debugRow("GPS authorization", authorizationLabel)
                debugRow("Has real fix", settings.hasRealLocation ? "yes" : "no")
                debugRow("Last coordinate", String(format: "%.5f, %.5f", settings.lastLatitude, settings.lastLongitude))
                debugRow("Fix count this launch", "\(locationService.revision)")
            }
            .font(.caption.monospaced())
            .foregroundStyle(OnTimeSpectrum.primaryText)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .spectrumCard()

            let driveBlocks = scratchBlocks.filter { $0.kind == .drive }
            if driveBlocks.isEmpty {
                Text("No drive steps to trace.")
                    .font(.caption)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
            } else {
                ForEach(driveBlocks) { block in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(block.name)
                            .font(.caption.weight(.medium))
                        debugRow("From", block.originPlace?.isCurrentLocation == true ? "Current Location" : (block.originPlace?.name ?? "none"))
                        debugRow("To", block.destinationPlace?.name ?? "none")
                        debugRow("Source", driveSourceLabel(for: block))
                        debugRow("Resolved minutes", "\(block.resolvedMinutes)")
                        if let at = block.resolvedAt {
                            debugRow("Resolved age", at.formatted(.relative(presentation: .numeric)))
                        }
                        debugRow("Manual/override minutes", "\(TravelTimeService.shared.manualEstimateMinutes(for: block))")
                        if let resolvedAt = travelService.resolvedAt(for: block) {
                            debugRow("Last resolved", resolvedAt.formatted(date: .omitted, time: .standard))
                        }
                        if let error = travelService.error(for: block) {
                            debugRow("Last error", error)
                                .foregroundStyle(OnTimeSpectrum.late)
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .spectrumCard()
                }

                Button("Force-Refresh Live ETAs") {
                    refreshDriveEstimates()
                }
                .font(InkType.label)
                .foregroundStyle(OnTimeSpectrum.primaryText)
            }
        }
    }

    private var authorizationLabel: String {
        switch locationService.authorization {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorized always"
        case .authorizedWhenInUse: return "authorized when in use"
        @unknown default: return "unknown"
        }
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(OnTimeSpectrum.secondaryText)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func driveSourceLabel(for block: Block) -> String {
        switch travelService.source(for: block) {
        case .live: return "Live"
        case .cached: return "Cached"
        case .manual: return "Manual"
        }
    }

    private func driveSourceColor(for block: Block) -> Color {
        switch travelService.source(for: block) {
        case .live: return OnTimeSpectrum.secondaryText
        case .cached: return OnTimeSpectrum.waiting
        case .manual: return OnTimeSpectrum.tertiaryText
        }
    }

    private func symbol(for block: Block) -> String {
        block.template?.symbol ?? block.kind.defaultSymbol
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Button(action: startRun) {
                VStack(spacing: 4) {
                    // Black on the white plate of a primary button, so the
                    // caption is the ink at the same 62% the label white is.
                    Text(scratchBlocks.isEmpty ? "Set timer for" : "Start in")
                        .font(InkType.labelSmall)
                        .foregroundStyle(OnTimeSpectrum.ink.opacity(0.62))
                    // Not another spectrum: Final Time above is this page's
                    // one rainbow. Two spectrum filled numbers on one screen
                    // is the point at which it stops meaning anything.
                    Text(TimeFormatting.spanWords(remaining))
                        .onTimeNumeral(InkType.numberSize)
                        .foregroundStyle(remaining < 0 ? OnTimeSpectrum.late : OnTimeSpectrum.ink)
                        .contentTransition(.numericText())
                        .animation(.default, value: remaining)
                }
            }
            .buttonStyle(SpectrumButtonStyle())

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start step 1 by")
                        .font(InkType.labelSmall)
                        .foregroundStyle(OnTimeSpectrum.secondaryText)
                    Button {
                        TimerShortcut.arm(for: mustStartAt)
                    } label: {
                        HStack(spacing: 5) {
                            Text(timeString(mustStartAt))
                                .font(InkType.value.monospacedDigit())
                                .foregroundStyle(OnTimeSpectrum.primaryText)
                            Image(systemName: "timer")
                                .font(.caption2)
                                .foregroundStyle(OnTimeSpectrum.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Current time")
                        .font(InkType.labelSmall)
                        .foregroundStyle(OnTimeSpectrum.secondaryText)
                    Text(now, style: .time)
                        .font(InkType.value.monospacedDigit())
                        .foregroundStyle(OnTimeSpectrum.secondaryText)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(OnTimeSpectrum.ink.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(OnTimeSpectrum.hairline).frame(height: 1)
        }
    }

    // MARK: - Mutations

    /// Flips the whole sequence end to end, in the data rather than in the
    /// display. Different thing from `AppSettings.sequenceNewestFirst`,
    /// which only changes which end of the list is on top: this one says the
    /// steps genuinely happen in the other order, which is what you want
    /// after typing a routine in backwards.
    private func reverseSequence() {
        let chronological = scratchBlocks.sorted { $0.order < $1.order }
        withAnimation(.easeInOut) {
            renumber(Array(chronological.reversed()))
        }
        refreshDriveEstimates()
    }

    /// Moves one step one row, in the direction it moves on screen. With
    /// `sequenceNewestFirst` on, the row above is the step that happens
    /// *later*, so the swap is done in display order and turned back into
    /// chronological order afterwards.
    private func move(_ block: Block, by offset: Int) {
        var shown = displayBlocks
        guard let index = shown.firstIndex(where: { $0.uuid == block.uuid }),
              shown.indices.contains(index + offset) else { return }
        shown.swapAt(index, index + offset)
        withAnimation(.easeInOut) {
            renumber(settings.sequenceNewestFirst ? Array(shown.reversed()) : shown)
        }
        refreshDriveEstimates()
    }

    /// Writes a chronological order back as a contiguous `0...n-1`, with any
    /// Wait until step pinned to the front: its duration is "time until the
    /// clock says X", which means nothing behind other steps. Reverse used to
    /// skip that pin and could leave one stranded at the end.
    private func renumber(_ chronological: [Block]) {
        let startAts = chronological.filter { $0.kind == .startAt }
        let rest = chronological.filter { $0.kind != .startAt }
        for (index, block) in (startAts + rest).enumerated() {
            block.order = index
        }
    }

    /// Renumbers the survivors to a clean, contiguous `0...n-1` right away.
    /// A gap or a duplicate `order` is a tied sort key, and SwiftData
    /// resolves a tie differently between fetches, which is what made steps
    /// swap places on their own after a delete.
    private func delete(_ block: Block) {
        modelContext.delete(block)
        let remaining = scratchBlocks.filter { $0 !== block }.sorted { $0.order < $1.order }
        for (index, survivor) in remaining.enumerated() {
            survivor.order = index
        }
    }

    private func clearSequence() {
        withAnimation(.easeInOut) {
            for block in scratchBlocks {
                modelContext.delete(block)
            }
        }
    }

    private func delete(_ shortcut: QuickShortcut) {
        modelContext.delete(shortcut)
        let survivors = shortcuts
            .filter { $0.persistentModelID != shortcut.persistentModelID }
            .sorted { $0.order < $1.order }
        for (index, survivor) in survivors.enumerated() {
            survivor.order = index
        }
    }

    // MARK: - Start

    /// Builds a real `Plan`/`Run` from the scratch blocks via `RunLauncher`,
    /// then hands the run back so the pager can slide onto its page.
    ///
    /// The run gets copies, the same way `ScheduleService.arm` spawns a
    /// routine. It used to be handed the scratch blocks themselves, which the
    /// `Plan` then claimed: the builder was empty the moment Start was
    /// pressed, and stopping a run started by mistake lost the sequence with
    /// it, since nothing lists plans. Clear is how the builder empties now.
    private func startRun() {
        var blocks = scratchBlocks.enumerated().map { index, block in
            let copy = block.copyForSpawn(order: index)
            modelContext.insert(copy)
            return copy
        }
        if blocks.isEmpty {
            let goBlock = Block(order: 0, name: "Go", kind: .flex)
            modelContext.insert(goBlock)
            blocks = [goBlock]
        }
        let run = RunLauncher.start(deadline: deadline, name: "By \(timeString(deadline))",
                                    blocks: blocks, in: modelContext)
        onStarted(run)
    }

    // MARK: - Formatting

    private func timeString(_ date: Date) -> String {
        TimeFormatting.clockString(date)
    }

    private func timeString(hour: Int, minute: Int) -> String {
        TimeFormatting.clockString(hour: hour, minute: minute)
    }
}

/// "Add" beside the shortcut chips, as its own view.
///
/// It was a computed property on `SequenceComposer` reading that screen's
/// `@State`, which meant it could only be presented from inside the pager —
/// the one place a sheet does not reliably present. Owning its own state
/// lets `NowView` present it from outside.
struct AddShortcutSheet: View {
    let initialTime: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QuickShortcut.order) private var shortcuts: [QuickShortcut]

    @State private var name = ""
    @State private var time = Date()

    /// The picker is a sheet of its own, which is fine here: this view is
    /// presented from `NowView`, outside the pager, so a presentation
    /// attached to it survives.
    @State private var pickingTime = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InkMetric.cardToCard) {
                    InkCard {
                        InkTextRow(placeholder: "Name", text: $name,
                                   autocapitalization: .words)
                    }

                    InkCard {
                        InkValueRow(title: "Time",
                                    value: TimeFormatting.clockString(time),
                                    chevron: true) { pickingTime = true }
                    }
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
                .padding(.bottom, InkMetric.section)
            }
            .scrollIndicators(.hidden)
            .inkNavigation(title: "Add shortcut")
            .onAppear { time = initialTime }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .inkToolbarButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .inkToolbarButton()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $pickingTime) {
                FullScreenTimePicker(title: "Shortcut time", date: $time)
            }
        }
    }

    private func add() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        // Sentence case ("Work", not "WORK") — this used to force full caps,
        // which read as shouting for a name the user typed themselves.
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let cased = trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        // Max plus one, not count: after a delete, `count` collides with a
        // surviving order value and the chips swap positions between fetches.
        let nextOrder = (shortcuts.map(\.order).max() ?? -1) + 1
        modelContext.insert(QuickShortcut(name: cased, hour: comps.hour ?? 0,
                                          minute: comps.minute ?? 0, order: nextOrder))
        dismiss()
    }
}
