import SwiftUI
import SwiftData

struct TemplateDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var template: TaskTemplate

    @State private var showingAddSample = false
    @State private var manualSampleMinutes: Int = 15

    private var learnedEstimate: Int {
        let obs = template.samples.map { DurationObservation(minutes: $0.minutes, recordedAt: $0.recordedAt) }
        let confidence: Confidence = AppSettings.shared.confidenceIsSafe ? .safe : .typical
        return Estimator.estimate(observations: obs, prior: template.manualEstimateMinutes, confidence: confidence)
    }

    private var sortedSamples: [DurationSample] {
        template.samples.sorted { $0.recordedAt > $1.recordedAt }
    }

    private var kindOptions: [ChipOption<BlockKind>] {
        [ChipOption(BlockKind.fixed, "Fixed"),
         ChipOption(BlockKind.drive, "Drive"),
         ChipOption(BlockKind.flex, "Flex")]
    }

    /// A `List` rather than a `ScrollView` only because the history rows
    /// swipe to delete. Every row in it is a card, so it reads the same.
    var body: some View {
        List {
            sectionLabelRow("LEARNED", first: true)

            VStack(spacing: InkMetric.cardToCard) {
                Text("\(learnedEstimate) min")
                    .font(InkType.number)
                    .monospacedDigit()
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
                    .spectrumCard()

                InkCard {
                    InkRow {
                        Text("Typed estimate")
                            .font(InkType.rowTitle)
                            .foregroundStyle(OnTimeSpectrum.primaryText)
                        Spacer(minLength: 8)
                        DurationScrubber(minutes: $template.manualEstimateMinutes)
                    }
                }
            }
            .inkListRow()

            sectionLabelRow("KIND")

            ChipPicker(options: kindOptions, selection: Binding(
                get: { template.kind },
                set: { template.kind = $0 }
            ))
            .inkListRow()

            sectionLabelRow("HISTORY · \(template.samples.count)")

            if sortedSamples.isEmpty {
                InkEmpty("No samples.")
                    .inkListRow()
            } else {
                ForEach(sortedSamples) { sample in
                    sampleRow(sample)
                        .inkListRow()
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                modelContext.delete(sample)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(OnTimeSpectrum.late)
                        }
                }
            }

            InkCard {
                InkButtonRow(title: "Add sample") { showingAddSample = true }
            }
            .inkListRow()
        }
        .inkList()
        .inkNavigation(title: template.name.uppercased())
        .sheet(isPresented: $showingAddSample) {
            addSampleSheet
        }
    }

    private func sectionLabelRow(_ text: String, first: Bool = false) -> some View {
        SectionLabel(text)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // The label sits 24 below the section before it and 12 above its
            // own card. The rows either side carry 5 of their own.
            .listRowInsets(EdgeInsets(top: first ? InkMetric.labelToCard : InkMetric.section - 5,
                                      leading: InkMetric.page,
                                      bottom: InkMetric.labelToCard - 5,
                                      trailing: InkMetric.page))
    }

    private func sampleRow(_ sample: DurationSample) -> some View {
        InkRow {
            Text("\(sample.minutes) min")
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(OnTimeSpectrum.primaryText)
            Spacer(minLength: 8)
            Text(sample.recordedAt, format: .dateTime.month().day().hour().minute())
                .font(InkType.rowMeta)
                .foregroundStyle(OnTimeSpectrum.tertiaryText)
        }
        .spectrumCard()
    }

    private var addSampleSheet: some View {
        NavigationStack {
            ScrollView {
                InkCard {
                    InkRow {
                        Text("Minutes")
                            .font(InkType.rowTitle)
                            .foregroundStyle(OnTimeSpectrum.primaryText)
                        Spacer(minLength: 8)
                        DurationScrubber(minutes: $manualSampleMinutes)
                    }
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
            }
            .scrollIndicators(.hidden)
            .inkNavigation(title: "ADD SAMPLE")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAddSample = false }
                        .inkToolbarButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let sample = DurationSample(minutes: manualSampleMinutes, recordedAt: Date(), template: template)
                        modelContext.insert(sample)
                        showingAddSample = false
                    }
                    .inkToolbarButton()
                }
            }
        }
    }
}
