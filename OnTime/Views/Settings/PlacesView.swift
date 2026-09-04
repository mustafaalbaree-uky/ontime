import SwiftUI
import SwiftData
import CoreLocation

struct PlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Place.name) private var places: [Place]

    /// nil while the sheet is closed; a transient, un-inserted `Place` when
    /// adding; an existing row when editing. Rows used to be uneditable, so
    /// fixing a typo'd coordinate meant delete and recreate, which orphaned
    /// every block and template pointing at the old row.
    @State private var editingPlace: PlaceDraft?

    var body: some View {
        List {
            ForEach(places) { place in
                Button {
                    guard !place.isCurrentLocation else { return }
                    editingPlace = PlaceDraft(existing: place)
                } label: {
                    PlaceRow(place: place)
                }
                .buttonStyle(.plain)
                .inkListRow()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(place)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(OnTimeSpectrum.late)
                }
            }
        }
        .inkList()
        .inkNavigation(title: "PLACES")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PlusButton { editingPlace = PlaceDraft(existing: nil) }
            }
        }
        .sheet(item: $editingPlace) { draft in
            PlaceFormSheet(draft: draft)
        }
        .onAppear {
            seedDefaultPlacesIfNeeded()
        }
    }

    private func delete(_ place: Place) {
        // Through the cleanup helper: blocks and templates hold unpaired
        // pointers at these rows, and a bare delete left them dangling, which
        // is an uncatchable crash on the next read.
        DeleteCleanup.delete(place, in: modelContext)
    }

    private func seedDefaultPlacesIfNeeded() {
        guard places.isEmpty else { return }
        _ = Place.currentLocationSentinel(in: modelContext)
        // Fixed seeds only once there is a real coordinate. Seeding from the
        // default (0, 0) silently pinned Home and Masjid in the Gulf of
        // Guinea, and every ETA through them was garbage with the cause
        // visible only in the developer panel.
        guard AppSettings.shared.hasRealLocation else { return }
        let home = Place(name: "Home", latitude: AppSettings.shared.lastLatitude, longitude: AppSettings.shared.lastLongitude)
        let masjid = Place(name: "Masjid", latitude: AppSettings.shared.lastLatitude, longitude: AppSettings.shared.lastLongitude)
        modelContext.insert(home)
        modelContext.insert(masjid)
    }
}

private struct PlaceRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.isCurrentLocation ? "location.fill" : "mappin")
                .foregroundStyle(OnTimeSpectrum.secondaryText)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(InkType.rowTitle)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                Text(place.isCurrentLocation
                     ? "Live device coordinates"
                     : String(format: "%.4f, %.4f", place.latitude, place.longitude))
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(InkMetric.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectrumCard()
    }
}

/// Sheet identity for add-or-edit; carries the row being edited (nil for a
/// new place).
private struct PlaceDraft: Identifiable {
    let id = UUID()
    let existing: Place?
}

private struct PlaceFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let draft: PlaceDraft

    @State private var name = ""
    @State private var latitude: Double = 0
    @State private var longitude: Double = 0

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Out of range coordinates fed MapKit routing garbage that failed into
    /// the manual tier with the cause visible nowhere; refuse them at entry.
    private var coordinatesValid: Bool {
        (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InkMetric.cardToCard) {
                    InkCard {
                        InkTextRow(placeholder: "Name", text: $name, autocapitalization: .words)
                    }

                    InkCard {
                        coordinateRow("Latitude", value: $latitude)
                        coordinateRow("Longitude", value: $longitude)
                        InkButtonRow(title: "Use current coordinates",
                                     enabled: AppSettings.shared.hasRealLocation) {
                            latitude = AppSettings.shared.lastLatitude
                            longitude = AppSettings.shared.lastLongitude
                        }
                    }

                    if !coordinatesValid {
                        Text("Out of range")
                            .font(InkType.rowMeta)
                            .foregroundStyle(OnTimeSpectrum.waiting)
                    }
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
                .padding(.bottom, InkMetric.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .inkNavigation(title: draft.existing == nil ? "NEW PLACE" : "EDIT PLACE")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .inkToolbarButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .inkToolbarButton()
                        .disabled(trimmedName.isEmpty || !coordinatesValid)
                }
            }
            .onAppear {
                if let place = draft.existing {
                    name = place.name
                    latitude = place.latitude
                    longitude = place.longitude
                }
            }
        }
    }

    private func coordinateRow(_ title: String, value: Binding<Double>) -> some View {
        InkRow {
            Text(title)
                .font(InkType.rowTitle)
                .foregroundStyle(OnTimeSpectrum.primaryText)
            Spacer(minLength: 8)
            TextField("", value: value, format: .number)
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(OnTimeSpectrum.primaryText)
                .tint(OnTimeSpectrum.primaryText)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
        }
    }

    private func save() {
        if let place = draft.existing {
            place.name = trimmedName
            place.latitude = latitude
            place.longitude = longitude
        } else {
            let place = Place(name: trimmedName, latitude: latitude, longitude: longitude)
            modelContext.insert(place)
        }
        dismiss()
    }
}
