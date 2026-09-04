import Foundation
import SwiftData

/// A named location a `Block` can start from or head to.
///
/// `isCurrentLocation` is a sentinel row meaning "wherever I am right now"
/// rather than a fixed pin — later stages resolve it against the device's
/// live location instead of `latitude`/`longitude`, which are meaningless on
/// that row.
@Model
final class Place {
    var name: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var isCurrentLocation: Bool = false

    init(name: String, latitude: Double = 0, longitude: Double = 0,
         isCurrentLocation: Bool = false) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.isCurrentLocation = isCurrentLocation
    }

    /// The one "wherever I am right now" row, created on first use.
    ///
    /// Three screens used to each inline their own version of this, which is
    /// how you end up with several sentinel rows: they look identical in the
    /// UI but hash to different `TravelCacheKey`s and pile up in the saved
    /// places list. Every caller goes through here instead.
    static func currentLocationSentinel(in context: ModelContext) -> Place {
        do {
            let existing = try context.fetch(
                FetchDescriptor<Place>(predicate: #Predicate { $0.isCurrentLocation })
            )
            if let found = existing.first { return found }
        } catch {
            // Inserting after a *failed* fetch is exactly how duplicate
            // sentinel rows happen — the row may well exist. Hand back a
            // transient, un-inserted one instead and let the next
            // successful fetch supply the real row.
            assertionFailure("Sentinel fetch failed: \(error)")
            return Place(name: "Current Location", isCurrentLocation: true)
        }
        let place = Place(name: "Current Location", isCurrentLocation: true)
        context.insert(place)
        return place
    }
}
