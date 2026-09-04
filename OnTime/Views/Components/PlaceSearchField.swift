import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// Search-as-you-type destination entry for a drive `Block`, backed by
/// `MKLocalSearchCompleter` — this is the piece `TravelTimeService` /
/// `MapKitTravelProvider` were missing: they already do a live MapKit ETA
/// once a `Place` exists, but the only way to get a `Place` was to
/// pre-register lat/long by hand in `PlacesView`. Picking a search result
/// here resolves it via `MKLocalSearch` and creates (or reuses, by name) a
/// `Place` row, so drive blocks can point anywhere without a separate trip
/// to the Places screen.
struct PlaceSearchField: View {
    let label: String
    @Binding var place: Place?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Place.name) private var savedPlaces: [Place]

    @State private var query = ""
    @State private var completer = SearchCompleter()
    @State private var isResolving = false
    @State private var isFocused = false
    @State private var locationFailure: String?
    @State private var isSelecting = false
    @State private var locationService = LocationService.shared

    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: place?.isCurrentLocation == true ? "location.fill" : "mappin.circle.fill")
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                TextField("", text: $query, prompt: Text(label)
                    .foregroundColor(OnTimeSpectrum.tertiaryText))
                    .font(.body)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                    .tint(OnTimeSpectrum.primaryText)
                    .onChange(of: query) { _, newValue in
                        // Only a change the *user* typed invalidates the
                        // selection. `select()` writes the chosen place's
                        // name into this field too, and without this guard
                        // that write immediately fired this handler and set
                        // `place = nil` — so every pick, chip or search
                        // result, silently unpicked itself the instant it
                        // was made. "Current Location" looked especially
                        // broken because the leftover text made it seem like
                        // the tap had done nothing but type a label.
                        if isSelecting {
                            isSelecting = false
                            return
                        }
                        place = nil
                        locationFailure = nil
                        completer.update(query: newValue)
                    }
                    .onTapGesture { isFocused = true }
                if isResolving {
                    ProgressView().controlSize(.small)
                } else if place != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(OnTimeSpectrum.done)
                }
            }

            // Selecting the sentinel used to write the words "Current
            // Location" into the text field and stop there, which is
            // indistinguishable from a tap that did nothing. Show what the
            // GPS actually came back with — acquiring, the street it landed
            // on, or why it couldn't.
            if place?.isCurrentLocation == true {
                HStack(spacing: 6) {
                    if locationService.isAcquiring {
                        ProgressView().controlSize(.small)
                            .tint(OnTimeSpectrum.secondaryText)
                        Text("Getting location…")
                            .foregroundStyle(OnTimeSpectrum.tertiaryText)
                    } else if let failure = locationFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(failure)
                    } else if settings.hasRealLocation {
                        Image(systemName: "location.fill")
                            .foregroundStyle(OnTimeSpectrum.secondaryText)
                        Text(locationService.lastFixDescription
                             ?? String(format: "%.4f, %.4f", settings.lastLatitude, settings.lastLongitude))
                            .foregroundStyle(OnTimeSpectrum.tertiaryText)
                    }
                }
                .font(InkType.rowMeta)
                .foregroundStyle(OnTimeSpectrum.waiting)
            } else if let failure = locationFailure {
                // A failed search-result resolution used to vanish here: the
                // spinner stopped, nothing was selected, and the most likely
                // read was "the tap didn't register."
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.waiting)
            }

            if query.isEmpty, place == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        // Pinned first and visually distinct from the
                        // generic saved-places chips below — it used to be
                        // just another same-style capsule buried in that
                        // scroller (or entirely invisible once this field's
                        // query got pre-filled with "Current Location" as
                        // literal search text), so "use my actual current
                        // location" had no reliable, findable affordance.
                        Button {
                            selectCurrentLocation()
                        } label: {
                            Chip(text: "Current Location", systemImage: "location.fill")
                        }
                        .buttonStyle(.plain)

                        ForEach(savedPlaces.filter { !$0.isCurrentLocation }) { saved in
                            Button { select(saved) } label: {
                                Chip(text: saved.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !completer.results.isEmpty && place == nil {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(completer.results.enumerated()), id: \.element) { index, result in
                        if index > 0 {
                            Rectangle()
                                .fill(OnTimeSpectrum.hairline)
                                .frame(height: 1)
                        }
                        Button {
                            resolve(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.title)
                                    .font(InkType.bodyText)
                                    .foregroundStyle(OnTimeSpectrum.primaryText)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(InkType.rowMeta)
                                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(OnTimeSpectrum.surface)
                .clipShape(RoundedRectangle(cornerRadius: InkMetric.innerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: InkMetric.innerRadius, style: .continuous)
                        .strokeBorder(OnTimeSpectrum.hairline, lineWidth: 1)
                }
            }
        }
        .padding(InkMetric.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // The "Current Location" sentinel's `name` is a label, not
            // something you'd ever want to search by — pre-filling the text
            // field with it used to hand `MKLocalSearchCompleter` the
            // literal string "Current Location", which ranks by text
            // relevance against real place names and surfaces whatever
            // random venue happens to be called that (a KY/OH/IN grab bag)
            // instead of anything near you. Leave the field blank so typing
            // starts a real search; the sentinel is still one tap away as a
            // chip below.
            if let place, !place.isCurrentLocation { query = place.name }
            updateSearchRegion()
        }
        .onChange(of: settings.hasRealLocation) { _, _ in updateSearchRegion() }
    }

    /// `MKLocalSearchCompleter` has no idea where you are unless told — with
    /// no `region` set it ranks results by raw text relevance, which is how
    /// "current location is totally broken" happens: it knows your
    /// coordinate, but the search box was never told to use it, so it
    /// happily suggests an address states away that just matches the typed
    /// text better. Biasing to a ~50km box around the last GPS fix is the
    /// same trick Maps' own search box uses, and it's what makes nearby
    /// results actually rank first instead of merely being included.
    private func updateSearchRegion() {
        guard settings.hasRealLocation else { return }
        let center = CLLocationCoordinate2D(latitude: settings.lastLatitude, longitude: settings.lastLongitude)
        completer.updateRegion(center: center)
    }

    private func select(_ saved: Place) {
        // Set the guard only when the assignment will actually change the
        // text — a no-op assignment never fires `onChange`, and a flag left
        // standing would swallow the user's next keystroke instead.
        if query != saved.name { isSelecting = true }
        query = saved.name
        place = saved
        completer.update(query: "")
    }

    /// Picks the sentinel *and* actually goes and gets a fix. The tap is the
    /// moment the user is watching, so it's the right moment to spend the
    /// second it takes — the ETA path can then route from a fresh coordinate
    /// instead of whatever was last cached, and the row above shows the
    /// result so "Current Location" is visibly a place, not a label.
    private func selectCurrentLocation() {
        let sentinel = Place.currentLocationSentinel(in: modelContext)
        select(sentinel)
        locationFailure = nil
        Task {
            do {
                _ = try await locationService.currentCoordinate(maxAge: 60)
            } catch {
                locationFailure = error.localizedDescription
            }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        isResolving = true
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, error in
            isResolving = false
            guard let item = response?.mapItems.first else {
                locationFailure = error?.localizedDescription
                    ?? "Could not resolve \(completion.title)."
                return
            }
            locationFailure = nil
            let coord = item.placemark.coordinate
            let name = completion.title

            // Reuse an existing saved Place with the same name/coordinate
            // rather than growing a duplicate every time the same spot is
            // searched again.
            if let existing = savedPlaces.first(where: { matches($0, name: name, coord: coord) }) {
                select(existing)
                return
            }

            let newPlace = Place(name: name, latitude: coord.latitude, longitude: coord.longitude)
            modelContext.insert(newPlace)
            select(newPlace)
        }
    }

    private func matches(_ candidate: Place, name: String, coord: CLLocationCoordinate2D) -> Bool {
        guard candidate.name == name else { return false }
        let latDelta = abs(candidate.latitude - coord.latitude)
        let lonDelta = abs(candidate.longitude - coord.longitude)
        return latDelta < 0.0001 && lonDelta < 0.0001
    }
}

/// Thin `@Observable` wrapper around `MKLocalSearchCompleter` — it only
/// talks to its delegate, so this bridges it to something a SwiftUI view
/// can bind against directly.
@Observable
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private(set) var results: [MKLocalSearchCompletion] = []

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// A tight box (~50km) around the given coordinate — small enough that
    /// results actually get ranked by nearness instead of the region just
    /// being a tie-breaker among otherwise-equal text matches.
    func updateRegion(center: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            return
        }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}
