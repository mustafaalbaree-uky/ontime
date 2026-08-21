import SwiftUI
import SwiftData
import CoreLocation

struct PlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Place.name) private var places: [Place]

    @State private var showingAddSheet = false
    @State private var newName = ""
    @State private var newLat: Double = 0
    @State private var newLon: Double = 0
    @State private var isCurrent = false

    var body: some View {
        List {
            Section {
                ForEach(places) { place in
                    HStack {
                        Image(systemName: place.isCurrentLocation ? "location.fill" : "mappin.and.ellipse")
                            .foregroundStyle(place.isCurrentLocation ? .blue : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                                .font(.body.weight(.medium))
                            if place.isCurrentLocation {
                                Text("Uses live device coordinates")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(String(format: "%.4f, %.4f", place.latitude, place.longitude))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete(perform: deletePlaces)
            } header: {
                Text("Saved Places")
            } footer: {
                Text("Places are used as origins and destinations for drive steps.")
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Place Name", text: $newName)
                        Toggle("Current Location", isOn: $isCurrent)
                    }

                    if !isCurrent {
                        Section("Coordinates") {
                            HStack {
                                Text("Latitude")
                                Spacer()
                                TextField("0.0", value: $newLat, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.decimalPad)
                            }
                            HStack {
                                Text("Longitude")
                                Spacer()
                                TextField("0.0", value: $newLon, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.decimalPad)
                            }
                            Button("Fill Current Coordinates") {
                                if AppSettings.shared.hasRealLocation {
                                    newLat = AppSettings.shared.lastLatitude
                                    newLon = AppSettings.shared.lastLongitude
                                }
                            }
                        }
                    }
                }
                .navigationTitle("New Place")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingAddSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let place = Place(
                                name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
                                latitude: newLat,
                                longitude: newLon,
                                isCurrentLocation: isCurrent
                            )
                            modelContext.insert(place)
                            newName = ""
                            newLat = 0
                            newLon = 0
                            isCurrent = false
                            showingAddSheet = false
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            seedDefaultPlacesIfNeeded()
        }
    }

    private func deletePlaces(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(places[index])
        }
    }

    private func seedDefaultPlacesIfNeeded() {
        if places.isEmpty {
            _ = Place.currentLocationSentinel(in: modelContext)
            let home = Place(name: "Home", latitude: AppSettings.shared.lastLatitude, longitude: AppSettings.shared.lastLongitude)
            let masjid = Place(name: "Masjid", latitude: AppSettings.shared.lastLatitude, longitude: AppSettings.shared.lastLongitude)
            modelContext.insert(home)
            modelContext.insert(masjid)
        }
    }
}
