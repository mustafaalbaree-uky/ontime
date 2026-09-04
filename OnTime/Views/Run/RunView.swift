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
                    } else if blocks.isEmpty {
                        InkEmpty("No steps.")
                            .padding(.horizontal, InkMetric.page)
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        runningLayout(engine)
                    }
                } else {
                    ProgressView()
                        .tint(OnTimeSpectrum.primaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .inkNavigation(title: (plan?.name ?? "Run").uppercased())
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
                    .inkToolbarButton()
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
                                .font(InkType.label)
                                .foregroundStyle(OnTimeSpectrum.primaryText)
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
                // Honest about the consequence: the Plan row survives in
                // the store, but no screen lists plans, so a cancelled
                // hand-built sequence is not recoverable from anywhere.
                // The old copy pointed at a "Plans" screen that was
                // deleted along with its tab.
                Text("The countdown and Live Activity end. The sequence cannot be reopened.")
            }
            .sheet(isPresented: $showingAddStep) {
                TemplateDrawerSheet(
                    templates: templates,
                    allowsOpenDuration: !blocks.contains { $0.kind.isOpenDuration }
                ) { template in
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
                Button("Continue", role: .cancel) {}
            } message: {
                Text("Live Activities are off for OnTime in iOS Settings.")
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

    // MARK: - Running layout

    /// The same shape as the Now screen, deliberately: the final time on top,
    /// the sequence under it, and how long until the next thing pinned to the
    /// bottom.
    ///
    /// It used to be a different screen entirely — a card describing the
    /// active step, then a `List` of "All Steps" in plain system styling,
    /// then a blue button — so opening Steps mid-run meant re-reading a
    /// layout you had not seen since you built the sequence, in a visual
    /// language the rest of the app had stopped using. Same information, same
    /// arrangement, means Steps is now the *editable* view of the page you
    /// were already looking at rather than a second screen about the same run.
    private func runningLayout(_ engine: RunEngine) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let message = engine.solutionErrorMessage {
                    // A swallowed solver error used to die silently here:
                    // an invalid plan (two open-duration steps, most likely)
                    // just blanked every leave-by time with nothing saying why.
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(OnTimeSpectrum.waiting)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .spectrumCard()
                }

                finalTimeHeader(engine)

                if let block = engine.currentBlock, block.kind == .walk {
                    WalkCard(engine: engine, block: block)
                }

                sequenceSection(engine)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { upNextBar(engine) }
    }

    /// The plan's deadline, in the same place and the same weight the
    /// composer gives it — but in plain white, not the moving spectrum.
    /// The composer keeps the rainbow on its Final Time because building a
    /// sequence is a screen you look at on purpose; this is the same number
    /// on a screen you glance at mid-run, and it does not need decorating
    /// twice.
    private func finalTimeHeader(_ engine: RunEngine) -> some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("FINAL TIME")

            Text(timeString(engine.plan?.deadline ?? Date()))
                .font(InkType.display)
                .monospacedDigit()
                .foregroundStyle(OnTimeSpectrum.primaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
            .spectrumCard()

            if let minutes = engine.latenessMinutes, minutes > 0 {
                Text("running \(minutes) min past this")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OnTimeSpectrum.late)
            }
        }
    }

    private func sequenceSection(_ engine: RunEngine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "THE SEQUENCE") {
                PlusButton { showingAddStep = true }
            }

            ForEach(Array(blocks.enumerated()), id: \.element.uuid) { index, block in
                stepRow(engine, block: block, index: index)
            }
        }
    }

    private func stepRow(_ engine: RunEngine, block: Block, index: Int) -> some View {
        let done = index < run.currentIndex
        let current = index == run.currentIndex
        let state: StepRowState = done ? .done : (current ? .current : .upcoming)

        return StepRowCard(
            symbol: done ? "checkmark.circle.fill"
                : (current && engine.isWaitingToStart ? "hourglass"
                   : (current ? "arrow.right.circle.fill"
                      : (block.template?.symbol ?? block.kind.defaultSymbol))),
            name: block.name,
            meta: meta(for: block, index: index),
            state: state,
            // Only not yet reached steps can be removed: a done or active
            // step has real elapsed time recorded against it that deleting
            // out from under the run would orphan.
            onDelete: index > run.currentIndex
                ? { deleteUpcomingSteps(engine, at: IndexSet(integer: index)) }
                : nil
        ) {
            stepTrailing(engine, block: block, done: done)
        }
    }

    private func meta(for block: Block, index: Int) -> [String] {
        var parts = ["STEP \(index + 1)"]
        if block.kind == .drive, let dest = block.destinationPlace {
            parts.append("to \(dest.name)")
        }
        if !block.isOpenEnded {
            parts.append("waits for tap")
        }
        return parts
    }

    @ViewBuilder
    private func stepTrailing(_ engine: RunEngine, block: Block, done: Bool) -> some View {
        if block.kind == .flex {
            badge("FLEX")
        } else if block.kind == .walk {
            badge("WALK")
        } else if let sched = engine.schedule(for: block) {
            switch sched.constraint {
            case .hardLeaveBy(let date):
                Text(timeString(date))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(done ? OnTimeSpectrum.tertiaryText : OnTimeSpectrum.primaryText)
            case .flexAbsorbs(let remaining):
                Text("flex \(Int((remaining / 60.0).rounded()))m")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(OnTimeSpectrum.waiting)
            }
        }
    }

    /// A kind is not a state, so it is not coloured.
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(InkType.label)
            .tracking(1.5)
            .foregroundStyle(OnTimeSpectrum.tertiaryText)
    }

    /// How long until the next thing, and the button that gets you there.
    private func upNextBar(_ engine: RunEngine) -> some View {
        let waiting = engine.isWaitingToStart
        let target = waiting ? engine.naturalStart : engine.currentBlock.flatMap(engine.leaveByDate(for:))
        let left = target.map { $0.timeIntervalSince(engine.now) }
        let late = (left ?? 0) < 0

        return VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(waiting ? "UNTIL START" : "UNTIL \((engine.currentBlock?.name ?? "NEXT").uppercased()) IS DUE")
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(OnTimeSpectrum.secondaryText)
                        .lineLimit(1)
                    if let left {
                        Text((late ? "+" : "") + TimeFormatting.countdownString(abs(left)))
                            .font(InkType.number)
                            .monospacedDigit()
                            .foregroundStyle(late ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText)
                    } else {
                        Text("…")
                            .font(InkType.number)
                            .foregroundStyle(OnTimeSpectrum.tertiaryText)
                    }
                }
                Spacer()
                if let t = target {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("AT")
                            .font(.caption2.weight(.bold))
                            .tracking(1.5)
                            .foregroundStyle(OnTimeSpectrum.secondaryText)
                        Text(timeString(t))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(OnTimeSpectrum.secondaryText)
                    }
                }
            }

            Button {
                if waiting { engine.beginFirstStepNow() } else { engine.advanceStep() }
            } label: {
                Label(waiting ? "Start Step 1 Now"
                      : (run.currentIndex + 1 >= blocks.count ? "Finish" : "Next Step"),
                      systemImage: waiting ? "play.fill" : "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
            }
            .buttonStyle(SpectrumButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(OnTimeSpectrum.ink.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(OnTimeSpectrum.hairline).frame(height: 1)
        }
    }

    // MARK: - Finished View

    private func finishedView(_ engine: RunEngine) -> some View {
        let diff = plan.map { $0.deadline.timeIntervalSince(now) }
        let late = (diff ?? 0) < 0

        return VStack(spacing: 16) {
            Spacer()

            Text("FINISHED")
                .font(InkType.label)
                .tracking(1.5)
                .foregroundStyle(OnTimeSpectrum.secondaryText)

            if let diff {
                let minutes = Int((abs(diff) / 60.0).rounded())
                Text("\(minutes) min \(late ? "late" : "early")")
                    .font(InkType.hero)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(late ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText)
            }

            if let p = plan {
                Text("\(p.name) · \(timeString(p.deadline))")
                    .font(InkType.bodyText)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, InkMetric.page)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Button {
                    RunEngineStore.shared.retire(run)
                    dismiss()
                } label: {
                    Text("Done")
                        .font(InkType.buttonProminent)
                        .foregroundStyle(OnTimeSpectrum.primaryText)
                }
                .buttonStyle(SpectrumButtonStyle())
            }
            .padding(.horizontal, InkMetric.page)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(OnTimeSpectrum.ink.opacity(0.96))
            .overlay(alignment: .top) {
                Rectangle().fill(OnTimeSpectrum.hairline).frame(height: 1)
            }
        }
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
            resolvedMinutes: minutes,
            // A remembered drive's route has to come along, or the inserted
            // step can never resolve a live ETA (and an inserted walk has
            // no home coordinate); `QuickBlockEditorSheet.apply` copies
            // these in the equivalent flow.
            originPlace: template?.originPlace,
            destinationPlace: template?.destinationPlace,
            useManualEstimateOnly: template?.useManualEstimateOnly ?? false
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
        let ordered = p.orderedBlocks
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

    // MARK: - Formatting

    private func timeString(_ date: Date) -> String {
        TimeFormatting.clockString(date)
    }

    private func formatDuration(_ ti: TimeInterval) -> String {
        let total = Int(ti.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
