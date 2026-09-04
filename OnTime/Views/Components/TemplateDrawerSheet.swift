import SwiftUI

/// "Add Step" mid-run: pick a remembered `TaskTemplate`, or build a one-off
/// step inline. Lived inside `PlanEditorView.swift` until that file was
/// deleted along with the Plans tab. `RunView` is the only caller now, so it
/// moved here rather than dying with its old host.
struct TemplateDrawerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let templates: [TaskTemplate]
    /// False once the plan already holds a flex or walk step: the solver can
    /// only solve for one open duration, so the drawer hides the Flex custom
    /// kind and filters open duration templates rather than letting the
    /// insert silently blank the whole schedule.
    var allowsOpenDuration: Bool = true
    let onSelect: (TaskTemplate) -> Void
    let onAddCustom: (BlockKind, String, Int) -> Void

    @State private var customName = ""
    @State private var customKind: BlockKind = .fixed
    @State private var customMinutes = 10

    private var offeredTemplates: [TaskTemplate] {
        allowsOpenDuration ? templates : templates.filter { !$0.kind.isOpenDuration }
    }

    private var kindOptions: [ChipOption<BlockKind>] {
        var options = [ChipOption(BlockKind.fixed, "Fixed"), ChipOption(BlockKind.drive, "Drive")]
        if allowsOpenDuration {
            options.append(ChipOption(BlockKind.flex, "Flex"))
        }
        return options
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InkMetric.section) {
                    beforeSection
                    customSection
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
                .padding(.bottom, InkMetric.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .inkNavigation(title: "ADD STEP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .inkToolbarButton()
                }
            }
        }
    }

    private var beforeSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("BEFORE")

            if offeredTemplates.isEmpty {
                InkEmpty("Nothing remembered.")
            } else {
                InkCard {
                    ForEach(offeredTemplates) { template in
                        Button {
                            onSelect(template)
                        } label: {
                            InkRow {
                                Image(systemName: template.symbol)
                                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(template.name)
                                        .font(InkType.rowTitle)
                                        .foregroundStyle(OnTimeSpectrum.primaryText)
                                    Text("\(template.manualEstimateMinutes) min · \(template.kind.rawValue.capitalized)")
                                        .font(InkType.rowMeta)
                                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "plus")
                                    .font(InkType.label)
                                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("CUSTOM")

            InkCard {
                InkTextRow(placeholder: "Name", text: $customName)

                InkRow {
                    ChipPicker(options: kindOptions, selection: $customKind)
                }

                if customKind != .flex {
                    InkRow {
                        DurationScrubber(minutes: $customMinutes)
                    }
                }

                InkButtonRow(title: "Add step",
                             enabled: !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    onAddCustom(customKind, customName.trimmingCharacters(in: .whitespacesAndNewlines), customMinutes)
                }
            }
        }
    }
}
