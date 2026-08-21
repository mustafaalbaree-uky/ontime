import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var locationService = LocationService.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Estimation") {
                    Toggle("Safe Confidence (p80)", isOn: $settings.confidenceIsSafe)
                    Text(settings.confidenceIsSafe
                         ? "Estimates use the 80th percentile to protect against being late."
                         : "Estimates use the 50th percentile (typical median duration).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Running") {
                    Toggle("Auto-Advance Steps", isOn: $settings.autoAdvanceEnabled)
                    Text(settings.autoAdvanceEnabled
                         ? "A step moves to the next one on its own once its estimated duration elapses. You can still tap Next early."
                         : "You tap Next Step to advance, which is also how actual durations get measured for future estimates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        LearnedStepsView()
                    } label: {
                        Label("Learned Steps", systemImage: "square.stack")
                    }
                } footer: {
                    Text("Steps get remembered automatically the first time you name one. This is where their measured durations live.")
                }

                Section("Travel") {
                    NavigationLink {
                        PlacesView()
                    } label: {
                        Label("Saved Places", systemImage: "mappin.and.ellipse")
                    }

                    Stepper("Lead Warning: \(settings.defaultLeadWarningMinutes) min",
                            value: $settings.defaultLeadWarningMinutes, in: 1...30)
                }

                Section("Location") {
                    HStack {
                        Text("GPS Status")
                        Spacer()
                        Text(settings.hasRealLocation ? "Acquired" : "Default / Stored")
                            .foregroundStyle(settings.hasRealLocation ? .green : .secondary)
                    }

                    if settings.hasRealLocation {
                        HStack {
                            Text("Coordinates")
                            Spacer()
                            Text(locationService.lastFixDescription
                                 ?? String(format: "%.4f, %.4f", settings.lastLatitude, settings.lastLongitude))
                                .foregroundStyle(.secondary)
                        }
                        // "Acquired" stays true forever once a fix has ever
                        // landed, so without the age it says the same thing
                        // for a coordinate from ten seconds ago and one from
                        // last Tuesday's parking spot.
                        if let at = settings.lastFixAt {
                            HStack {
                                Text("Last Fix")
                                Spacer()
                                Text(at, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(locationService.isAcquiring ? "Getting Location…" : "Request Live Location") {
                        locationService.requestLocation()
                    }
                    .disabled(locationService.isAcquiring)
                }

                Section("Developer") {
                    Toggle("Developer Mode", isOn: $settings.developerModeEnabled)
                    Text("Shows a debug panel on the Now screen: GPS fix state and per drive-step ETA source/errors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(buildStamp)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var buildStamp: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
