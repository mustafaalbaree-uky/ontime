import SwiftUI
import SwiftData

/// What the app has learned about how long things actually take you.
///
/// This was the Templates tab. It stopped deserving a tab once naming a step
/// anywhere in the app created its template automatically
/// (`QuickBlockEditorSheet.resolveTemplate`): there was never a reason to
/// come here to *make* one, only to look at or correct what got measured. So
/// it lives in Settings now, and there is no "new template" button. A
/// template with no step behind it is a row that can never learn anything.
struct LearnedStepsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskTemplate.name) private var templates: [TaskTemplate]

    var body: some View {
        List {
            if templates.isEmpty {
                InkEmpty("Nothing learned.")
                    .inkListRow()
            } else {
                ForEach(templates) { template in
                    NavigationLink {
                        TemplateDetailView(template: template)
                    } label: {
                        LearnedStepRow(template: template)
                    }
                    .buttonStyle(.plain)
                    .inkListRow()
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            delete(template)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(OnTimeSpectrum.late)
                    }
                }
            }
        }
        .inkList()
        .inkNavigation(title: "LEARNED STEPS")
    }

    private func delete(_ template: TaskTemplate) {
        // Through the cleanup helper: blocks on every screen hold unpaired
        // `template` pointers, and a bare delete left them dangling, which is
        // an uncatchable crash on the next property read.
        DeleteCleanup.delete(template, in: modelContext)
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
                .foregroundStyle(OnTimeSpectrum.secondaryText)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(InkType.rowTitle)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                Text(template.samples.isEmpty
                     ? "Not measured"
                     : "\(template.samples.count) measured")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
            }

            Spacer(minLength: 8)

            StepRowValue(
                text: "\(learned) min",
                caption: (!template.samples.isEmpty && learned != template.manualEstimateMinutes)
                    ? "typed \(template.manualEstimateMinutes)"
                    : nil
            )
        }
        .padding(InkMetric.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectrumCard()
    }
}
