import SwiftUI
import SwiftData
import UIKit

struct RunView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let run: Run

    @State private var engine: RunEngine?
    @State private var showingCancelConfirm = false
    @State private var showingAddStep = false
    @State private var showingTemplateDrawer = false
    @Query(sort: \TaskTemplate.name) private var templates: [TaskTemplate]

    private var plan: Plan? { engine?.plan }
    private var blocks: [Block] { engine?.blocks ?? [] }
    private var now: Date { engine?.now ?? Date() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let engine {
                    if engine.isFinished {
                        finishedView(engine)
                    } else if engine.isWaitingToStart, let target = engine.naturalStart {
                        waitTimeView(engine, target)
                        stepsListView(engine)
                    } else if let block = engine.currentBlock {
                        activeBlockView(engine, block)
                        stepsListView(engine)
                        controlsView(engine)
                    } else {
                        ContentUnavailableView("No Steps in Plan", systemImage: "exclamationmark.triangle")
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(plan?.name ?? "Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Just closes the screen — the run keeps going in the
                    // background (see `RunEngine`/`RunEngineStore`) and is
                    // reachable again from Current Countdowns. This used to
                    // be "Exit" meaning "stop the run," which is why closing
                    // this screen by mistake felt like it wiped the whole
                    // sequence.
                    Button("Close") {
                        dismiss()
                    }
                }
                if let engine, !engine.isFinished {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                engine.autoAdvance.toggle()
                            } label: {
                                Label(engine.autoAdvance ? "Switch to Manual" : "Switch to Auto",
                                      systemImage: engine.autoAdvance ? "hand.tap.fill" : "play.circle.fill")
                            }
                            Button {
                                showingAddStep = true
                            } label: {
                                Label("Add Step", systemImage: "plus.circle")
                            }
                            Button(role: .destructive) {
                                showingCancelConfirm = true
                            } label: {
                                Label("Cancel Run", systemImage: "xmark.circle")
                            }
                        } label: {
                            Label(engine.autoAdvance ? "Auto" : "Manual",
                                  systemImage: engine.autoAdvance ? "play.circle.fill" : "hand.tap.fill")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .onAppear {
                engine = RunEngineStore.shared.engine(for: run)
            }
            .confirmationDialog(
                "Cancel this run?",
                isPresented: $showingCancelConfirm,
                titleVisibility: .visible
            ) {
                Button("Cancel Run", role: .destructive) {
                    if let engine { RunEngineStore.shared.cancel(engine.run) }
                    dismiss()
                }
                Button("Keep Running", role: .cancel) {}
            } message: {
                Text("This stops the countdown and Live Activity for good. Your plan and its steps aren't deleted — you can start it again from Plans.")
            }
            .sheet(isPresented: $showingAddStep) {
                TemplateDrawerSheet(templates: templates) { template in
                    insertStep(name: template.name, kind: template.kind, minutes: template.manualEstimateMinutes, template: template)
                } onAddCustom: { kind, name, minutes in
                    insertStep(name: name, kind: kind, minutes: minutes, template: nil)
                }
            }
            .alert("Live Activities are off", isPresented: .init(
                get: { engine?.showingActivitiesDisabledAlert ?? false },
                set: { if !$0 { engine?.showingActivitiesDisabledAlert = false } }
            )) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Continue without it", role: .cancel) {}
            } message: {
                Text("Turn on Live Activities for OnTime in Settings to get a Dynamic Island / Lock Screen countdown. This run still tracks fine without it.")
            }
            .alert("Couldn't start Live Activity", isPresented: .init(
                get: { engine?.startFailureMessage != nil },
                set: { if !$0 { engine?.startFailureMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(engine?.startFailureMessage ?? "")
            }
        }
    }

    // MARK: - Active Block Header

    private func activeBlockView(_ engine: RunEngine, _ block: Block) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("STEP \(run.currentIndex + 1) OF \(blocks.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if block.kind == .flex {
                    Text("FLEX STEP")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 12) {
                Image(systemName: block.template?.symbol ?? block.kind.defaultSymbol)
                    .font(.title)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(block.name)
                        .font(.title2.bold())
                    if block.kind == .drive, let dest = block.destinationPlace {
                        Text("Heading to \(dest.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let targetDate = engine.leaveByDate(for: block) {
                let diff = targetDate.timeIntervalSince(now)
                let overrun = engine.isCurrentBlockOverrun
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.targetLabel(for: block))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(timeString(targetDate))
                            .font(.title3.bold().monospacedDigit())
                        // The projection, shown only when it disagrees with
                        // the target. Two times for one step used to appear
                        // on this screen with nothing to tell them apart —
                        // the header counted from when the step actually
                        // began, the row below and the notifications from
                        // the deadline — so a late start read as the app
                        // contradicting itself. Now the target is the
                        // target, and the drift says it is drift.
                        if let projected = engine.projectedEnd(for: block),
                           abs(projected.timeIntervalSince(targetDate)) >= 60 {
                            let lateBy = Int((projected.timeIntervalSince(targetDate) / 60).rounded())
                            Text(lateBy > 0
                                 ? "Heading for \(timeString(projected)), \(lateBy)m late"
                                 : "Heading for \(timeString(projected)), \(-lateBy)m early")
                                .font(.caption2)
                                .foregroundStyle(lateBy > 0 ? Color.orange : Color.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        // No "Overdue" — past the estimate just means one of
                        // two things, both fine: it already auto-advanced
                        // (this state won't be visible), or it's waiting on
                        // a manual tap, which "Waiting on you" says plainly
                        // instead of implying something went wrong.
                        Text(diff >= 0 ? "Remaining" : (overrun ? "Waiting on you" : "Running"))
                            .font(.caption)
                            .foregroundStyle(diff >= 0 ? Color.secondary : (overrun ? Color.orange : Color.secondary))
                        Text(formatDuration(abs(diff)))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(diff >= 0 ? Color.primary : (overrun ? Color.orange : Color.primary))
                        if overrun, let lateness = engine.latenessMinutes {
                            Text(lateness > 0 ? "pushes finish ~\(lateness)m late" : "still on time")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(diff >= 0 ? Color.accentColor.opacity(0.1) : (overrun ? Color.orange.opacity(0.12) : Color.accentColor.opacity(0.1)))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - Wait Time (pre-Step-1)

    private func waitTimeView(_ engine: RunEngine, _ target: Date) -> some View {
        VStack(spacing: 8) {
            if let block = engine.currentBlock {
                HStack(spacing: 12) {
                    Image(systemName: block.template?.symbol ?? block.kind.defaultSymbol)
                        .font(.title)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        // Says what's happening right now (waiting), not
                        // what happens next (starting the step).
                        Text("Wait Time")
                            .font(.title2.bold())
                    }
                    Spacer()
                }
            }

            let diff = target.timeIntervalSince(now)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start step 1 by")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        armTimer(for: target)
                    } label: {
                        HStack(spacing: 6) {
                            Text(timeString(target))
                                .font(.title3.bold().monospacedDigit())
                            Image(systemName: "timer")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(diff >= 0 ? "Remaining" : "Late")
                        .font(.caption)
                        .foregroundStyle(diff >= 0 ? Color.secondary : Color.red)
                    Text(formatDuration(abs(diff)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(diff >= 0 ? Color.primary : Color.red)
                }
            }
            .padding()
            .background(diff >= 0 ? Color.accentColor.opacity(0.1) : Color.red.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                engine.beginFirstStepNow()
            } label: {
                HStack {
                    Spacer()
                    Text("Start Step 1 Now")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding()
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - Steps List

    private func stepsListView(_ engine: RunEngine) -> some View {
        List {
            Section("All Steps") {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    HStack(spacing: 12) {
                        if index < run.currentIndex {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if index == run.currentIndex && engine.isWaitingToStart {
                            Image(systemName: "hourglass")
                                .foregroundStyle(.orange)
                        } else if index == run.currentIndex {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.tint)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(block.name)
                                .font(.body.weight(index == run.currentIndex ? .bold : .regular))
                                .foregroundStyle(index < run.currentIndex ? .secondary : .primary)

                            if block.kind == .flex {
                                Text("Flex step")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("\(TravelTimeService.shared.manualEstimateMinutes(for: block)) min")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if let sched = engine.schedule(for: block) {
                            switch sched.constraint {
                            case .hardLeaveBy(let date):
                                Text(timeString(date))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(index < run.currentIndex ? .secondary : .primary)
                            case .flexAbsorbs(let rem):
                                let remMin = Int((rem / 60.0).rounded())
                                Text("flex: \(remMin)m")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                // Only not-yet-reached steps can be safely removed — a done
                // or currently-active step has real elapsed time recorded
                // against it that deleting out from under the run would
                // orphan.
                .onDelete { offsets in
                    deleteUpcomingSteps(engine, at: offsets)
                }

                Button {
                    showingAddStep = true
                } label: {
                    Label("Add Step", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - Controls

    private func controlsView(_ engine: RunEngine) -> some View {
        VStack(spacing: 8) {
            Button {
                engine.advanceStep()
            } label: {
                HStack {
                    Spacer()
                    Text(run.currentIndex + 1 >= blocks.count ? "Finish Run" : "Next Step")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding()
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Finished View

    private func finishedView(_ engine: RunEngine) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            Text("Run Complete!")
                .font(.largeTitle.bold())

            if let p = plan {
                let diff = p.deadline.timeIntervalSince(now)
                if diff >= 0 {
                    let minsEarly = Int((diff / 60.0).rounded())
                    Text("You made it with \(minsEarly) min to spare!")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else {
                    let minsLate = Int((-diff / 60.0).rounded())
                    Text("Finished \(minsLate) min past deadline.")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Button("Done") {
                RunEngineStore.shared.retire(run)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
        .padding()
        .onAppear {
            RunEngineStore.shared.retire(run)
        }
    }

    // MARK: - Mid-run editing

    /// Inserted immediately before the current step while waiting
    /// (`isWaitingToStart`) — the countdown the user is watching
    /// automatically becomes the countdown to this new first step, and
    /// `naturalStart` shifts earlier by the new step's own duration on the
    /// very next tick, since it's recomputed live from every block
    /// including this one. Inserted immediately *after* the current step
    /// once the run is actually underway, since a step already in progress
    /// can't have something spliced in front of it.
    private func insertStep(name: String, kind: BlockKind, minutes: Int, template: TaskTemplate?) {
        guard let engine, let p = plan else { return }
        let insertAt = engine.isWaitingToStart ? run.currentIndex : run.currentIndex + 1
        // `TravelTimeService.manualEstimateMinutes` reads
        // `estimateOverrideMinutes` before it ever looks at
        // `resolvedMinutes` — mirroring `PlanEditorView.addCustomBlock`,
        // the working reference, since a template's own minutes still need
        // to win when one was picked (template = carries its own default,
        // no override needed).
        let newBlock = Block(
            order: insertAt,
            name: name,
            kind: kind,
            template: template,
            estimateOverrideMinutes: template == nil ? minutes : nil,
            resolvedMinutes: minutes
        )
        newBlock.plan = p
        modelContext.insert(newBlock)

        var ordered = p.orderedBlocks
        ordered.removeAll { $0.id == newBlock.id }
        let clampedIndex = min(insertAt, ordered.count)
        ordered.insert(newBlock, at: clampedIndex)
        for (i, b) in ordered.enumerated() { b.order = i }

        showingAddStep = false
        engine.recomputeSolution()
        engine.syncLiveActivityAndNotifications()
    }

    private func deleteUpcomingSteps(_ engine: RunEngine, at offsets: IndexSet) {
        guard let p = plan else { return }
        var ordered = p.orderedBlocks
        for index in offsets {
            guard index > run.currentIndex || (index == run.currentIndex && engine.isWaitingToStart) else { continue }
            modelContext.delete(ordered[index])
        }
        p.renumber()
        // Deleting the only remaining upcoming steps can leave
        // `currentIndex >= blocks.count` with `finishedAt` still nil —
        // every other path to that state (`advanceStep` running off the
        // end, `reconcile`'s tail) sets `finishedAt` itself; this is the
        // one that doesn't, and without it the run would look "finished"
        // to `isFinished` (stopping the engine) while still showing as
        // live in Current Countdowns (which filters on `finishedAt == nil`).
        if run.currentIndex >= p.orderedBlocks.count, run.finishedAt == nil {
            run.finishedAt = Date()
        }
        engine.recomputeSolution()
        engine.syncLiveActivityAndNotifications()
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

    private func formatDuration(_ ti: TimeInterval) -> String {
        let total = Int(ti.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
