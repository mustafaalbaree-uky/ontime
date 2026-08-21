import SwiftUI
import SwiftData
import UIKit

/// The front screen the app is actually about, ported from the HTML
/// prototype (`~/Code/time app.html`) but no longer a simplified second
/// system: the sequence here is real `Block`s (`plan == nil && routine ==
/// nil` — "scratch" blocks, claimed by a `Plan` the moment a run starts),
/// the same type `ScheduledRoutineEditor` uses. That merge is deliberate —
/// this screen used to run on `QuickStep` (bare minutes, no name, no kind,
/// no template), a second half-built system living alongside the real one,
/// which is exactly why "what's the difference between Plans/Routines/
/// Templates?" was a fair question to ask. Those three tabs are gone now
/// and this is the front of the app: the fast path into the same engine,
/// via `QuickBlockEditorSheet` and `RunLauncher`.
///
/// Anything that runs on its own lives behind the "Scheduled" button
/// (`ScheduledRoutinesView`), and an armed routine appears as a banner at
/// the top without displacing whatever is already on the board.
///
/// Two deliberate departures from the prototype, both per explicit product
/// direction rather than oversight:
/// - The deadline is a plain time field. No automatic prayer-time lookup —
///   if the deadline is an iqama, the user types that time in themselves.
/// - Shortcut chips are entirely user-defined (`QuickShortcut`); nothing is
///   pre-seeded, unlike the prototype's hardcoded FAJR/ISHA/9AM.
struct NowView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QuickShortcut.order) private var shortcuts: [QuickShortcut]
    @Query(filter: #Predicate<Block> { $0.plan == nil && $0.routine == nil }, sort: \Block.order)
    private var scratchBlocks: [Block]

    private var settings: AppSettings { .shared }
    private var locationService: LocationService { .shared }
    private var travelService: TravelTimeService { .shared }

    @State private var now = Date()
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var showingAddStep = false
    @State private var editingBlock: Block?
    @State private var showingAddShortcut = false
    @State private var showingFinalTimePicker = false
    @State private var showingScheduled = false
    @State private var newShortcutName = ""
    @State private var newShortcutTime = Date()

    /// Set the moment Start builds a `Run`, presented full-screen — landing
    /// here *is* the confirmation that starting actually worked, which is
    /// strictly better feedback than a checkmark on a button that stays on
    /// this screen: no more wondering whether the tap did anything.
    @State private var activeRun: Run?

    // MARK: - Derived time

    /// Resolved fresh from the stored hour/minute on every tick, so the
    /// deadline rolls to tomorrow on its own the moment it passes — see
    /// `DeadlineResolver`. Only the deadline rolls; a start time already in
    /// the past just means the plan is late, not that it's for tomorrow.
    private var deadline: Date {
        DeadlineResolver.resolve(hour: settings.quickDeadlineHour, minute: settings.quickDeadlineMinute,
                                  now: now, calendar: .current)
    }

    /// nil when there are no steps yet — "must start" collapses to the
    /// deadline itself, same as the prototype's `totalPrepMins === 0` case.
    /// A drive block uses `driveMinutes(for:)` — its live-refreshed ETA
    /// once `refreshDriveEstimates()` resolves one — everything else uses
    /// `TravelTimeService.manualEstimateMinutes`, same as
    /// `RunView.recomputeSolution`.
    private var mustStartAt: Date {
        guard !scratchBlocks.isEmpty else { return deadline }
        let durations: [BlockDuration] = scratchBlocks.map { block in
            if block.kind == .flex { return .flex }
            let minutes = block.kind == .drive ? driveMinutes(for: block) : TravelTimeService.shared.manualEstimateMinutes(for: block)
            return .known(TimeInterval(minutes * 60))
        }
        let input = SolverInput(durations: durations, deadline: deadline, start: nil, pinnedFlex: nil)
        guard let solution = try? Solver.solve(input) else { return deadline }
        return solution.start
    }

    private var remaining: TimeInterval { mustStartAt.timeIntervalSince(now) }

    /// The order this screen displays blocks in, top to bottom: last step
    /// first, first step last. Final Time sits at the very top of the
    /// screen, so the step that runs right before it belongs directly
    /// underneath; the step you'd actually start on lands at the bottom,
    /// next to the Start button. `scratchBlocks` itself stays in
    /// chronological order (lowest `order` = first step) for the solver and
    /// `RunLauncher`, which both need that, not the display order.
    private var displayBlocks: [Block] { Array(scratchBlocks.reversed()) }

    /// The `order` a newly-added block should get: strictly after every
    /// existing block, so it's last chronologically and lands at the top of
    /// `displayBlocks`. Using `scratchBlocks.count` here used to collide
    /// with an existing block's `order` once a block had been deleted
    /// without the rest being renumbered — a duplicate sort key, which is
    /// exactly what made the new step flash into place at the top and then
    /// swap somewhere else on the next redraw as SwiftData resolved the tie
    /// differently between fetches.
    private var nextScratchOrder: Int { (scratchBlocks.map(\.order).max() ?? -1) + 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ArmedRoutineBanner(now: now) { activeRun = $0 }
                header
                sequenceSection
                if settings.developerModeEnabled {
                    developerPanel
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .background(Color(uiColor: .systemBackground))
        .onReceive(timer) { now = $0 }
        .onAppear {
            locationService.requestLocation()
            refreshDriveEstimates()
        }
        .onChange(of: scratchBlocks) { _, _ in refreshDriveEstimates() }
        .sheet(isPresented: $showingAddStep) {
            QuickBlockEditorSheet(existingBlock: nil, newBlockOrder: nextScratchOrder, isFirstPosition: scratchBlocks.isEmpty) { refreshDriveEstimates() }
        }
        .sheet(item: $editingBlock) { block in
            QuickBlockEditorSheet(existingBlock: block, newBlockOrder: 0, isFirstPosition: block.order == (scratchBlocks.map(\.order).min() ?? block.order)) { refreshDriveEstimates() }
        }
        .sheet(isPresented: $showingAddShortcut) { addShortcutSheet }
        .sheet(isPresented: $showingFinalTimePicker) {
            FullScreenTimePicker(title: "Final Time", date: deadlineTimeBinding)
        }
        .sheet(isPresented: $showingScheduled) {
            ScheduledRoutinesView()
        }
        .fullScreenCover(item: $activeRun) { run in
            RunView(run: run)
        }
    }

    /// Fires a live MapKit ETA lookup for every drive step currently on the
    /// board. Nothing on `NowView` used to call `TravelTimeService.resolve`
    /// at all — a drive block's "X min" was always just the manual estimate
    /// (override → template default → 10) until a `Run` actually started,
    /// which is why adding two real locations produced no feedback here.
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
            HStack {
                Text("FINAL TIME")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                Spacer()
                // Everything that runs on its own lives behind here — this
                // screen stays about the thing in front of you.
                Button {
                    showingScheduled = true
                } label: {
                    Label("Scheduled", systemImage: "repeat")
                        .font(.caption.weight(.bold))
                        .labelStyle(.titleAndIcon)
                }
            }

            Button {
                showingFinalTimePicker = true
            } label: {
                Text(timeString(deadlineTimeBinding.wrappedValue))
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shortcuts) { shortcut in
                        Button {
                            settings.quickDeadlineHour = shortcut.hour
                            settings.quickDeadlineMinute = shortcut.minute
                        } label: {
                            Text("\(shortcut.name) \(timeString(hour: shortcut.hour, minute: shortcut.minute))")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.bordered)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(shortcut) }
                        }
                    }

                    Button {
                        newShortcutName = ""
                        newShortcutTime = deadlineTimeBinding.wrappedValue
                        showingAddShortcut = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor.opacity(0.2))
                }
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
            HStack {
                Text("THE SEQUENCE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                Spacer()
                Button {
                    showingAddStep = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
            }

            if !scratchBlocks.isEmpty {
                ForEach(displayBlocks) { block in
                    Button {
                        editingBlock = block
                    } label: {
                        blockRow(block)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Developer panel

    /// `AppSettings.developerModeEnabled`-gated debug view — the internals
    /// that would otherwise take a debugger to see: GPS fix state, and per
    /// drive-block which tier (`live`/`cached`/`manual`) actually answered
    /// and why, so "current location isn't doing anything" and "no
    /// feedback" are diagnosable from the phone itself.
    private var developerPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DEVELOPER MODE")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
                .tracking(1)

            VStack(alignment: .leading, spacing: 6) {
                debugRow("GPS authorization", authorizationLabel)
                debugRow("Has real fix", settings.hasRealLocation ? "yes" : "no")
                debugRow("Last coordinate", String(format: "%.5f, %.5f", settings.lastLatitude, settings.lastLongitude))
                debugRow("Fix count this launch", "\(locationService.revision)")
            }
            .font(.caption.monospaced())
            .padding()
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            let driveBlocks = scratchBlocks.filter { $0.kind == .drive }
            if driveBlocks.isEmpty {
                Text("No drive steps to trace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(driveBlocks) { block in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(block.name)
                            .font(.caption.weight(.bold))
                        debugRow("From", block.originPlace?.isCurrentLocation == true ? "Current Location" : (block.originPlace?.name ?? "—"))
                        debugRow("To", block.destinationPlace?.name ?? "—")
                        debugRow("Source", driveSourceLabel(for: block))
                        debugRow("Resolved minutes", "\(block.resolvedMinutes)")
                        debugRow("Manual/override minutes", "\(TravelTimeService.shared.manualEstimateMinutes(for: block))")
                        if let resolvedAt = travelService.resolvedAt(for: block) {
                            debugRow("Last resolved", resolvedAt.formatted(date: .omitted, time: .standard))
                        }
                        if let error = travelService.error(for: block) {
                            debugRow("Last error", error)
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption.monospaced())
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button("Force-Refresh Live ETAs") {
                    refreshDriveEstimates()
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
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
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func blockRow(_ block: Block) -> some View {
        HStack {
            Image(systemName: symbol(for: block))
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(block.name)
                    .font(.body.weight(.semibold))
                HStack(spacing: 6) {
                    Text("STEP \(block.order + 1)")
                    if block.kind == .drive, let dest = block.destinationPlace {
                        Text("• to \(dest.name)")
                    }
                    if block.kind == .startAt, let hour = block.targetHour, let minute = block.targetMinute {
                        Text("• at \(timeString(hour: hour, minute: minute))")
                    }
                    if !block.isOpenEnded {
                        Text("• waits for tap")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if block.kind == .drive, let error = travelService.error(for: block) {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            if block.kind == .flex {
                Text("FLEX")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            } else if block.kind == .drive {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(driveMinutes(for: block)) min")
                        .font(.title3.bold())
                    Text(driveSourceLabel(for: block))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(driveSourceColor(for: block))
                }
            } else {
                Text("\(TravelTimeService.shared.manualEstimateMinutes(for: block)) min")
                    .font(.title3.bold())
            }

            Button {
                delete(block)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor(for: block))
                .frame(width: 4)
        }
    }

    private func accentColor(for block: Block) -> Color {
        switch block.kind {
        case .flex: return .orange
        case .startAt: return .blue
        case .fixed, .drive: return .accentColor
        }
    }

    /// The live-resolved ETA when one exists, falling back to the manual
    /// estimate — same precedence `PlanEditorView`/`RunView` use for a
    /// drive block. `manualEstimateMinutes` alone is wrong here: it checks
    /// `estimateOverrideMinutes` first, which `QuickBlockEditorSheet`
    /// always sets, so a live ETA from `resolve(block:)` would otherwise
    /// never be shown.
    private func driveMinutes(for block: Block) -> Int {
        block.resolvedMinutes > 0 ? block.resolvedMinutes : TravelTimeService.shared.manualEstimateMinutes(for: block)
    }

    private func driveSourceLabel(for block: Block) -> String {
        switch travelService.source(for: block) {
        case .live: return "LIVE"
        case .cached: return "CACHED"
        case .manual: return "MANUAL"
        }
    }

    private func driveSourceColor(for block: Block) -> Color {
        switch travelService.source(for: block) {
        case .live: return .green
        case .cached: return .orange
        case .manual: return .secondary
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
                    Text(scratchBlocks.isEmpty ? "Set timer for" : "Start")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(1)
                    Text(formatDuration(remaining))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(remaining < 0 ? .red : .accentColor)
                        .contentTransition(.numericText())
                        .animation(.default, value: remaining)
                    Text(remaining < 0 ? "overdue — starts a countdown from now" : "tap to start a live countdown")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start step 1 by")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Button {
                        armTimer(for: mustStartAt)
                    } label: {
                        HStack(spacing: 5) {
                            Text(timeString(mustStartAt))
                                .font(.headline)
                            Image(systemName: "timer")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("CURRENT TIME")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(now, style: .time)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Add shortcut

    private var addShortcutSheet: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. Work)", text: $newShortcutName)
                    .textInputAutocapitalization(.characters)
                DatePicker("Time", selection: $newShortcutTime, displayedComponents: .hourAndMinute)
            }
            .navigationTitle("Add Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddShortcut = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addShortcut() }
                        .font(.headline)
                        .disabled(newShortcutName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Mutations

    /// Renumbers the survivors to a clean, contiguous `0...n-1` right away —
    /// leaving a gap is exactly what let a later add's `order` collide with
    /// an existing one (see `nextScratchOrder`).
    private func delete(_ block: Block) {
        modelContext.delete(block)
        let remaining = scratchBlocks.filter { $0 !== block }.sorted { $0.order < $1.order }
        for (index, survivor) in remaining.enumerated() {
            survivor.order = index
        }
    }

    private func addShortcut() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: newShortcutTime)
        // Sentence case ("Work", not "WORK") — this used to force full caps,
        // which read as shouting for a name the user typed themselves.
        let trimmed = newShortcutName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
        let shortcut = QuickShortcut(name: name, hour: comps.hour ?? 0, minute: comps.minute ?? 0, order: shortcuts.count)
        modelContext.insert(shortcut)
        showingAddShortcut = false
    }

    private func delete(_ shortcut: QuickShortcut) {
        modelContext.delete(shortcut)
    }

    // MARK: - Start

    /// Builds a real `Plan`/`Run` from the scratch blocks (via
    /// `RunLauncher`, the same path `QuickStartSheet` uses) and presents
    /// `RunView` — the live countdown screen itself is the confirmation
    /// that Start worked; `RunView` owns the actual Live Activity request
    /// from here.
    private func startRun() {
        var blocks = scratchBlocks
        if blocks.isEmpty {
            let goBlock = Block(order: 0, name: "Go", kind: .flex)
            modelContext.insert(goBlock)
            blocks = [goBlock]
        }
        activeRun = RunLauncher.start(deadline: deadline, name: "By \(timeString(deadline))", blocks: blocks, in: modelContext)
    }

    // MARK: - Timer

    /// Opens the "OnTime Timer" Shortcut with the calculated duration.
    /// The Shortcut creates an actual timer in the Clock app.
    private func armTimer(for target: Date) {
        guard target > Date() else { return }

        let seconds = max(1, Int(target.timeIntervalSince(Date()).rounded()))

        // Open the "OnTime Timer" Shortcut with the calculated duration
        // The Shortcut accepts the number of seconds as input
        let encodedSecondsText = "\(seconds)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(seconds)"
        let urlString = "shortcuts://run-shortcut?name=OnTime%20Timer&input=text&text=\(encodedSecondsText)"

        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Formatting

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func timeString(hour: Int, minute: Int) -> String {
        String(format: "%d:%02d", hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour), minute)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(ceil(interval / 60))
        guard totalMinutes > 0 else { return "0 Mins" }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 { return "\(h) Hr \(m) Mins" }
        return "\(m) Mins"
    }
}

#Preview {
    NowView()
}
