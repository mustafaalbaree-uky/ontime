import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var locationService = LocationService.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Refreshed on every appearance and foreground: nothing else in the
    /// app ever re-reads notification authorization after the launch
    /// prompt, so one denial used to silently kill the routine arm alarms,
    /// step alerts, and every walk alarm with no indication anywhere.
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TopBar(title: "SETTINGS")

                ScrollView {
                    VStack(alignment: .leading, spacing: InkMetric.section) {
                        if notificationsDenied { permissionSection }
                        estimatesSection
                        runningSection
                        notificationsSection
                        stepsSection
                        travelSection
                        walksSection
                        locationSection
                        developerSection
                        aboutSection
                    }
                    .padding(.horizontal, InkMetric.page)
                    .padding(.bottom, InkMetric.section)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .spectrumBackground()
            .toolbar(.hidden, for: .navigationBar)
            .task { await refreshNotificationStatus() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshNotificationStatus() }
            }
        }
    }

    // MARK: - Sections

    private var permissionSection: some View {
        section("NOTIFICATIONS") {
            InkTextLine(text: "Notifications are off for OnTime.",
                        color: OnTimeSpectrum.waiting, font: InkType.bodyText)
            InkButtonRow(title: "Open iOS Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        }
    }

    private var estimatesSection: some View {
        section("ESTIMATES") {
            InkToggleRow(title: "Safe estimates (p80)", isOn: $settings.confidenceIsSafe)
        }
    }

    private var runningSection: some View {
        section("RUNNING") {
            InkToggleRow(title: "Auto advance steps", isOn: $settings.autoAdvanceEnabled)
            InkToggleRow(title: "Last step on top", isOn: $settings.sequenceNewestFirst)
        }
    }

    private var notificationsSection: some View {
        section("NOTIFICATIONS") {
            InkToggleRow(title: "Sound", isOn: $settings.notificationSoundEnabled)
            InkToggleRow(title: "Early warning per step", isOn: $settings.leadWarningsEnabled)
            InkStepperRow(title: "Early warning", value: $settings.defaultLeadWarningMinutes,
                          range: 1...30, unit: "min")
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("STEPS")
            InkCard {
                NavigationLink {
                    LearnedStepsView()
                } label: {
                    InkNavRow(title: "Learned steps", symbol: "square.stack")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var travelSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("TRAVEL")
            InkCard {
                NavigationLink {
                    PlacesView()
                } label: {
                    InkNavRow(title: "Saved places", symbol: "mappin.and.ellipse")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var walksSection: some View {
        section("WALKS") {
            InkStepperRow(title: "Safety margin", value: $settings.walkSafetyPercent,
                          range: 0...50, step: 5, unit: "%")
            InkStepperRow(title: "Heads up", value: $settings.walkHeadsUpMinutes,
                          range: 0...30, unit: "min")
        }
    }

    private var locationSection: some View {
        section("LOCATION") {
            InkValueRow(title: "GPS",
                        value: settings.hasRealLocation ? "Acquired" : "Stored",
                        valueColor: settings.hasRealLocation ? OnTimeSpectrum.done : OnTimeSpectrum.secondaryText)

            if settings.hasRealLocation {
                InkValueRow(title: "Coordinates",
                            value: locationService.lastFixDescription
                                ?? String(format: "%.4f, %.4f", settings.lastLatitude, settings.lastLongitude),
                            valueColor: OnTimeSpectrum.secondaryText)
                if let at = settings.lastFixAt {
                    InkValueRow(title: "Last fix",
                                value: at.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)),
                                valueColor: OnTimeSpectrum.secondaryText)
                }
            }

            InkButtonRow(title: locationService.isAcquiring ? "Getting location…" : "Request location",
                         enabled: !locationService.isAcquiring) {
                locationService.requestLocation()
            }
        }
    }

    private var developerSection: some View {
        section("DEVELOPER") {
            InkToggleRow(title: "Developer mode", isOn: $settings.developerModeEnabled)
            if settings.developerModeEnabled {
                InkButtonRow(title: "Clear ETA cache") {
                    TravelTimeService.shared.clearCache()
                }
            }
        }
    }

    private var aboutSection: some View {
        section("ABOUT") {
            InkValueRow(title: "Build", value: buildStamp,
                        valueColor: OnTimeSpectrum.secondaryText)
        }
    }

    /// A label over one card of rows, which is what every section here is.
    private func section<Content: View>(_ label: String,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel(label)
            InkCard { content() }
        }
    }

    private func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
    }

    private var buildStamp: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
