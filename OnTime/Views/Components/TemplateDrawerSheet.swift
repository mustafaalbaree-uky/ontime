import SwiftUI

/// "Add Step" mid-run: pick a remembered `TaskTemplate`, or build a one-off
/// step inline. Lived inside `PlanEditorView.swift` until that file was
/// deleted along with the Plans tab — `RunView` is the only caller now, so
/// it moved here rather than dying with its old host.
struct TemplateDrawerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let templates: [TaskTemplate]
    let onSelect: (TaskTemplate) -> Void
    let onAddCustom: (BlockKind, String, Int) -> Void

    @State private var customName = ""
    @State private var customKind: BlockKind = .fixed
    @State private var customMinutes = 10

    var body: some View {
        NavigationStack {
            List {
                Section("Steps You've Done Before") {
                    if templates.isEmpty {
                        Text("Nothing remembered yet — steps get remembered automatically once you name them. Add a custom step below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(templates) { template in
                            Button {
                                onSelect(template)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: template.symbol)
                                        .font(.title3)
                                        .frame(width: 28)
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(template.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("\(template.manualEstimateMinutes) min • \(template.kind.rawValue.capitalized)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("Custom Step") {
                    TextField("Step Name", text: $customName)
                    Picker("Kind", selection: $customKind) {
                        Text("Fixed").tag(BlockKind.fixed)
                        Text("Drive").tag(BlockKind.drive)
                        Text("Flex (Open)").tag(BlockKind.flex)
                    }
                    if customKind != .flex {
                        LabeledContent("Duration") {
                            DurationScrubber(minutes: $customMinutes)
                        }
                    }
                    Button("Add Custom Step") {
                        onAddCustom(customKind, customName.trimmingCharacters(in: .whitespacesAndNewlines), customMinutes)
                    }
                    .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
