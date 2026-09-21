import SwiftUI
import MapKit
import CoreLocation

/// The header shown while a `.walk` block is the active step, in place of
/// the ordinary count-down-to-a-duration header.
///
/// Every other block kind shows one number, because every other block kind
/// has one: time left. A walk has no duration, so the interesting number is
/// a comparison instead, and the screen is built around the two forms that
/// comparison takes. Heading out it is "how much further can I go," which
/// is a live decision. Heading back it is "am I going to make it," which is
/// a different question with a different answer, and showing both at once
/// would just mean neither got read.
struct WalkCard: View {
    let engine: RunEngine
    let block: Block

    // Same convention as `NowView.travelService`: a computed reference to
    // the singleton, not `@State`. `WalkTracker` is `@Observable`, so
    // reading its properties in `body` is what registers the dependency.
    private var tracker: WalkTracker { .shared }

    private var now: Date { engine.now }
    private var isReturning: Bool { tracker.phase == .returning }
    private var slack: TimeInterval { tracker.slack(now: now) ?? 0 }
    private var mustTurnBack: Bool { !isReturning && slack <= 0 }

    var body: some View {
        VStack(spacing: 12) {
            header
            headline
            factsRow
            if !isReturning { outboundRoom }
            sourceLine
            buttons
        }
        .padding(InkMetric.heroPadding)
        .frame(maxWidth: .infinity)
        .spectrumCard(fill: mustTurnBack ? OnTimeSpectrum.late.opacity(0.10) : OnTimeSpectrum.surface)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Step \(engine.run.currentIndex + 1) of \(engine.blocks.count)")
                .font(InkType.label)
                .foregroundStyle(OnTimeSpectrum.secondaryText)
            Spacer()
            // A phase is not a state worth spending colour on, and the two
            // it used to spend were the blue this app never uses and the
            // green it reserves for finished.
            Text(isReturning ? "Heading back" : "Walking out")
                .font(InkType.label)
                .foregroundStyle(OnTimeSpectrum.secondaryText)
        }
    }

    // MARK: The one big number

    @ViewBuilder
    private var headline: some View {
        VStack(spacing: 4) {
            if isReturning {
                Text("Home by \(clock(tracker.homeBy))")
                    .font(InkType.labelSmall)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                Text("Arriving \(clock(tracker.projectedArrival(now: now)))")
                    .onTimeNumeral(InkType.heroSize)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(arrivalColor)
                Text(arrivalVerdict)
                    .font(InkType.bodyText)
                    .foregroundStyle(arrivalColor)
            } else if mustTurnBack {
                // No countdown here on purpose. Past the turnaround the
                // remaining number is negative, and a negative countdown is
                // a puzzle to read at exactly the moment there is no
                // attention to spare for one.
                Text("Turn around now")
                    .font(OnTimeSpectrum.numeral(InkType.numberSize))
                    .foregroundStyle(OnTimeSpectrum.late)
                    .multilineTextAlignment(.center)
                Text("\(minutes(tracker.estimate.seconds)) min back")
                    .font(InkType.bodyText)
                    .foregroundStyle(OnTimeSpectrum.late)
            } else {
                Text("Turn back in")
                    .font(InkType.labelSmall)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                Text(countdown(slack))
                    .onTimeNumeral(InkType.heroSize)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(slack < 300 ? OnTimeSpectrum.waiting : OnTimeSpectrum.primaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Supporting numbers

    private var factsRow: some View {
        HStack(spacing: 0) {
            fact("Out", value: "\(minutes(tracker.elapsed)) min")
            columnRule
            fact("Back", value: "~\(minutes(tracker.estimate.seconds)) min")
            columnRule
            fact(isReturning ? "Deadline" : "Be back", value: clock(tracker.homeBy))
        }
    }

    private var columnRule: some View {
        Rectangle()
            .fill(OnTimeSpectrum.rule)
            .frame(width: 1, height: 26)
    }

    private func fact(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(InkType.labelSmall)
                .foregroundStyle(OnTimeSpectrum.secondaryText)
            Text(value)
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(OnTimeSpectrum.primaryText)
        }
        .frame(maxWidth: .infinity)
    }

    /// The number that is useful for the whole walk rather than only at the
    /// instant the alarm fires. Half the slack, because a minute spent
    /// walking further out has to be walked back over as well.
    private var outboundRoom: some View {
        Text(roomText)
            .font(InkType.rowMeta)
            .foregroundStyle(OnTimeSpectrum.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var roomText: String {
        let room = tracker.remainingOutbound(now: now) ?? 0
        if room < 60 { return "No room out" }
        return "\(minutes(room)) min of room out"
    }

    /// Says which of the three estimates answered, and at what pace. An
    /// estimate with no provenance invites either too much trust or too
    /// little, and the difference between "the map routed you home" and
    /// "we are assuming you retrace your steps" changes what you would do
    /// with the number.
    @ViewBuilder
    private var sourceLine: some View {
        if let reason = tracker.unavailableReason {
            warning(reason, symbol: "location.slash")
        } else if tracker.notificationsDenied {
            // The alarm is the feature's safety net; with notifications off
            // it silently never fires, so this walk is screen only.
            warning("Notifications are off. No turn around alert.", symbol: "bell.slash")
        } else if let locError = tracker.locationError {
            warning(locError, symbol: "location.slash")
        } else {
            Text(sourceText)
                .font(InkType.rowMeta)
                .foregroundStyle(OnTimeSpectrum.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func warning(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(InkType.rowMeta)
            .foregroundStyle(OnTimeSpectrum.waiting)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var sourceText: String {
        let pace = tracker.pace.map { String(format: "%.1f mph", $0 * 2.23694) }
        switch tracker.estimate.source {
        case .routedAtMyPace:
            return "Route home at your pace" + (pace.map { " (\($0))" } ?? "")
        case .routed:
            return "Route home at Maps pace"
        case .retrace:
            return "No route yet. Retracing your path."
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: InkMetric.cardToCard) {
            if isReturning {
                Button {
                    tracker.markOutbound()
                } label: {
                    Label("Still Out", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SpectrumButtonStyle(prominent: false))
            } else {
                Button {
                    tracker.markReturning()
                } label: {
                    Label("Heading Back", systemImage: "arrow.uturn.left")
                }
                // Past the turnaround this button used to wear a `late`
                // outline. Buttons have no outline now; the card's red fill
                // and the red headline above already say it.
                .buttonStyle(SpectrumButtonStyle())
            }

            // The map owns the turn by turn; this app owns the deadline.
            // Handing off rather than drawing a route means there is one
            // place to look for each question instead of a worse copy of
            // Maps living inside a timer.
            Button {
                openInMaps()
            } label: {
                Label("Route", systemImage: "map")
            }
            .buttonStyle(SpectrumButtonStyle(prominent: false))
            .disabled(tracker.homeCoordinate == nil)
            .opacity(tracker.homeCoordinate == nil ? 0.38 : 1)
        }
    }

    private func openInMaps() {
        guard let home = tracker.homeCoordinate else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: home))
        item.name = block.destinationPlace?.name ?? "Home"
        item.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }

    // MARK: Presentation

    private var arrivalColor: Color {
        guard let homeBy = tracker.homeBy else { return OnTimeSpectrum.primaryText }
        let over = tracker.projectedArrival(now: now).timeIntervalSince(homeBy)
        if over > 60 { return OnTimeSpectrum.late }
        if over > -120 { return OnTimeSpectrum.waiting }
        return OnTimeSpectrum.primaryText
    }

    private var arrivalVerdict: String {
        guard let homeBy = tracker.homeBy else { return "" }
        let over = tracker.projectedArrival(now: now).timeIntervalSince(homeBy)
        if over > 30 { return "\(minutes(over)) min late" }
        let spare = minutes(-over)
        return spare <= 0 ? "On time" : "\(spare) min spare"
    }

    private func minutes(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds / 60).rounded()))
    }

    private func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func clock(_ date: Date?) -> String {
        guard let date else { return "…" }
        return TimeFormatting.clockString(date)
    }
}
