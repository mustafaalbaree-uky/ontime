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

    var body: some View {
        Form {
            Section("Estimate") {
                HStack {
                    Text("Learned Duration")
                    Spacer()
                    Text("\(learnedEstimate) min")
                        .font(.title3.bold())
                        .foregroundStyle(.tint)
                }

                LabeledContent("Manual Prior") {
                    DurationScrubber(minutes: $template.manualEstimateMinutes)
                }

                Picker("Kind", selection: Binding(
                    get: { template.kind },
                    set: { template.kind = $0 }
                )) {
                    Text("Fixed").tag(BlockKind.fixed)
                    Text("Drive").tag(BlockKind.drive)
                    Text("Flex (Absorbs)").tag(BlockKind.flex)
                }
            }

            Section {
                if sortedSamples.isEmpty {
                    Text("No duration observations recorded yet. Samples will be automatically saved when you complete runs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedSamples) { sample in
                        HStack {
                            Text("\(sample.minutes) min")
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(sample.recordedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteSample)
                }

                Button {
                    showingAddSample = true
                } label: {
                    Label("Add Manual Sample", systemImage: "plus")
                }
            } header: {
                Text("Observation History (\(template.samples.count) total)")
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddSample) {
            NavigationStack {
                Form {
                    LabeledContent("Observed Duration") {
                        DurationScrubber(minutes: $manualSampleMinutes)
                    }
                }
                .navigationTitle("Add Sample")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddSample = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let sample = DurationSample(minutes: manualSampleMinutes, recordedAt: Date(), template: template)
                            modelContext.insert(sample)
                            showingAddSample = false
                        }
                    }
                }
            }
        }
    }

    private func deleteSample(at offsets: IndexSet) {
        let samplesToDelete = offsets.map { sortedSamples[$0] }
        for sample in samplesToDelete {
            modelContext.delete(sample)
        }
    }
}
