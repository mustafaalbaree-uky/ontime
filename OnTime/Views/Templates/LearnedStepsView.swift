import SwiftUI
import SwiftData

/// What the app has learned about how long things actually take you.
///
/// This was the Templates tab. It stopped deserving a tab once naming a step
/// anywhere in the app created its template automatically
/// (`QuickBlockEditorSheet.resolveTemplate`) — there was never a reason to
/// come here to *make* one, only to look at or correct what got measured. So
/// it lives in Settings now, and there's no "new template" button: a
/// template with no step behind it is a row that can never learn anything.
struct LearnedStepsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskTemplate.name) private var templates: [TaskTemplate]

    var body: some View {
        List {
            if templates.isEmpty {
                ContentUnavailableView(
                    "Nothing Learned Yet",
                    systemImage: "square.stack",
                    description: Text("Name a step when you add one and it shows up here. Tap through your steps as you finish them — that's what gets measured.")
                )
            } else {
                ForEach(templates) { template in
                    NavigationLink {
                        TemplateDetailView(template: template)
                    } label: {
                        LearnedStepRow(template: template)
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .navigationTitle("Learned Steps")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(templates[index])
        }
    }
}

private struct LearnedStepRow: View {
    let template: TaskTemplate

    private var learned: Int {
        let observations = template.samples.map {
            DurationObservation(minutes: $0.minutes, recordedAt: $0.recordedAt)
        }
        return Estimator.estimate(
            observations: observations,
            prior: template.manualEstimateMinutes,
            confidence: AppSettings.shared.confidenceIsSafe ? .safe : .typical
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: template.symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.body.weight(.medium))
                Text(template.samples.isEmpty
                     ? "Never measured — using your \(template.manualEstimateMinutes) min guess"
                     : "\(template.samples.count) measurement\(template.samples.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(learned) min")
                    .font(.headline)
                if !template.samples.isEmpty, learned != template.manualEstimateMinutes {
                    Text("you guessed \(template.manualEstimateMinutes)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
