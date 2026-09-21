import SwiftUI
import WidgetKit

/// The Home Screen widget: what is running, and what is scheduled next.
///
/// It reads `OnTimeWidgetSnapshot` out of the App Group container — never
/// the SwiftData store, see that file for why — and every value in it is an
/// absolute wall-clock date the app already worked out. That is what lets
/// this stay correct for days without the app being opened: nothing here is
/// relative to when the snapshot was written.
///
/// **Deliberately monochrome.** A widget cannot move, and this one is a list
/// you read at arm's length while doing something else. White on black, no
/// colour at all; an occurrence that has not woken up yet is a dimmed row. A
/// step whose time has passed is never drawn: the run is on its next step by
/// then (`LiveRun.shown(at:)`), and off the widget after its last.
///
/// Type is look A, the same as the app and the Live Activity: SF Pro at
/// regular weight, thin or light numerals through `onTimeNumeral`, sentence
/// case, no tracking. It used to be SF Rounded bold with tracked capitals.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OnTimeWidgetStore.kind, provider: UpNextProvider()) { entry in
            UpNextView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Your live countdown and the routines coming up.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

// MARK: - Timeline

struct UpNextEntry: TimelineEntry {
    let date: Date
    let snapshot: OnTimeWidgetSnapshot
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        completion(UpNextEntry(date: Date(), snapshot: OnTimeWidgetStore.read() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        let now = Date()
        let snapshot = OnTimeWidgetStore.read() ?? .empty

        // One entry per moment something in the snapshot actually changes —
        // a countdown reaching its target, a routine's window opening, an
        // occurrence dropping off the end — plus a slow heartbeat so a
        // widget with nothing imminent still refreshes its "in 3h" style
        // labels. Requesting a fixed every-15-minutes timeline instead would
        // spend the system's whole refresh budget redrawing identical
        // pixels, and then have none left at the boundary that mattered.
        var dates = snapshot.changePoints(after: now)
        var heartbeat = now.addingTimeInterval(15 * 60)
        let horizon = now.addingTimeInterval(6 * 3600)
        while heartbeat < horizon {
            dates.append(heartbeat)
            heartbeat = heartbeat.addingTimeInterval(15 * 60)
        }
        dates = Set(dates).sorted().prefix(60).map { $0 }

        let entries = [UpNextEntry(date: now, snapshot: snapshot)]
            + dates.map { UpNextEntry(date: $0, snapshot: snapshot) }

        // `.after` rather than `.atEnd`: the last entry may be days out (a
        // weekly routine), and the snapshot on disk will have been rewritten
        // long before then. Six hours is the point at which asking again is
        // worth it even if nothing is scheduled.
        let reloadAt = min(dates.last ?? horizon, horizon)
        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }
}

// MARK: - View

struct UpNextView: View {
    let entry: UpNextEntry
    @Environment(\.widgetFamily) private var family

    private var run: OnTimeWidgetSnapshot.LiveRun? {
        entry.snapshot.liveRuns(at: entry.date).first
    }

    private var upcoming: [OnTimeWidgetSnapshot.Upcoming] {
        entry.snapshot.upcoming(after: entry.date, limit: upcomingLimit)
    }

    private var upcomingLimit: Int {
        switch family {
        case .systemLarge: return run == nil ? 7 : 5
        case .systemMedium: return run == nil ? 3 : 1
        default: return 1
        }
    }

    var body: some View {
        content
            .widgetBackground()
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryRectangular: accessory
        case .systemSmall: small
        default: stack
        }
    }

    // MARK: Small

    @ViewBuilder
    private var small: some View {
        if let run {
            VStack(alignment: .leading, spacing: 6) {
                RunLine(run: run, now: entry.date, compact: true)
                Spacer(minLength: 0)
                Text(run.stepName.isEmpty ? run.name : run.stepName)
                    .font(.system(size: 13))
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                    .lineLimit(2)
                StepPips(index: run.stepIndex, total: run.totalSteps)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if let next = upcoming.first {
            VStack(alignment: .leading, spacing: 6) {
                Text("Next")
                    .font(.system(size: 12))
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
                Text(next.name)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(WidgetFormat.clock(next.deadline))
                    .onTimeNumeral(28)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(WidgetFormat.startLine(next, now: entry.date))
                    .font(.system(size: 12))
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            EmptyState()
        }
    }

    // MARK: Medium / Large

    @ViewBuilder
    private var stack: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 12 : 8) {
            if let run {
                VStack(alignment: .leading, spacing: 7) {
                    RunLine(run: run, now: entry.date, compact: false,
                            countdownSize: family == .systemLarge ? 44 : 34)
                    StepPips(index: run.stepIndex, total: run.totalSteps)
                }
                if !upcoming.isEmpty {
                    Divider().overlay(OnTimeSpectrum.hairline)
                }
            }

            if upcoming.isEmpty && run == nil {
                EmptyState()
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(upcoming) { item in
                        UpcomingRow(item: item, now: entry.date)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Lock Screen

    @ViewBuilder
    private var accessory: some View {
        if let run {
            VStack(alignment: .leading, spacing: 1) {
                Text(run.stepName.isEmpty ? run.name : run.stepName)
                    .font(.caption)
                    .lineLimit(1)
                // Regular, not light: the Lock Screen draws an accessory in
                // its own vibrant material, where a light stroke washes out.
                CountdownText(target: run.target, now: entry.date, size: 22,
                              weight: .regular)
                Text("\(run.targetLabel) \(WidgetFormat.clock(run.target ?? run.deadline))")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let next = upcoming.first {
            VStack(alignment: .leading, spacing: 1) {
                Text(next.name).font(.caption).lineLimit(1)
                Text(WidgetFormat.clock(next.deadline))
                    .font(.system(size: 22, weight: .regular))
                    .monospacedDigit()
                Text(WidgetFormat.startLine(next, now: entry.date))
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Nothing scheduled")
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Pieces

/// The live run's countdown and what it is aimed at.
private struct RunLine: View {
    let run: OnTimeWidgetSnapshot.LiveRun
    let now: Date
    let compact: Bool
    var countdownSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: run.symbol)
                    .font(.system(size: 11))
                // As the app hands it over ("Finish by"), not uppercased.
                Text(run.targetLabel)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if !compact, let target = run.target {
                    Text(WidgetFormat.clock(target))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                }
                Spacer(minLength: 0)
                if !compact {
                    Text(run.name)
                        .font(.system(size: 12))
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(OnTimeSpectrum.secondaryText)

            CountdownText(target: run.target, now: now, size: compact ? 32 : countdownSize)

            if !compact {
                Text(run.stepName.isEmpty ? run.name : run.stepName)
                    .font(.system(size: 15))
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

/// The countdown itself.
///
/// Never `Text(_:style: .timer)`: that view counts down to its date and then,
/// with no sign and no relabelling, starts counting up, so a number rising
/// through 00:41 looks identical to one falling through it. The range form
/// clamps at both ends by itself. There is no form for a target that has
/// passed, because `LiveRun.shown(at:)` never hands one over.
private struct CountdownText: View {
    let target: Date?
    let now: Date
    let size: CGFloat
    /// nil takes the weight `OnTimeSpectrum.numeral` picks for the size.
    var weight: Font.Weight? = nil

    private var font: Font {
        weight.map { .system(size: size, weight: $0) } ?? OnTimeSpectrum.numeral(size)
    }

    private var tracking: CGFloat { OnTimeSpectrum.numeralTracking(size) }

    var body: some View {
        if let target, target > now {
            Text(timerInterval: now...target, countsDown: true)
                .font(font)
                .monospacedDigit()
                .tracking(tracking)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        } else {
            Text("…")
                .font(font)
                .foregroundStyle(.white.opacity(0.38))
        }
    }
}

/// One row of bars for the sequence, in the same three whites and the same
/// 3 pt height as the Live Activity's pips and the run page's strip. The
/// only thing worth reading here is how far along the run is.
private struct StepPips: View {
    let index: Int
    let total: Int

    var body: some View {
        if total > 1 {
            HStack(spacing: 3) {
                ForEach(0..<total, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i == index ? Color.white.opacity(0.95)
                              : (i < index ? Color.white.opacity(0.30) : Color.white.opacity(0.12)))
                        .frame(height: 3)
                }
            }
        }
    }
}

private struct UpcomingRow: View {
    let item: OnTimeWidgetSnapshot.Upcoming
    let now: Date

    /// Dimmed until the routine's own window opens, which is the one thing
    /// this list can usefully distinguish: a row that is going to wake the
    /// phone up soon versus one that is still a day away.
    private var armed: Bool { now >= item.armAt }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(armed ? 0.8 : 0.35))
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(armed ? 1 : 0.75))
                    .lineLimit(1)
                Text(WidgetFormat.startLine(item, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(WidgetFormat.clock(item.deadline))
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(armed ? 1 : 0.62))
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing scheduled")
                .font(.system(size: 15))
                .foregroundStyle(OnTimeSpectrum.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Formatting

enum WidgetFormat {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// "start 5:52" today, "Tue • start 5:52" any later day. The start time
    /// is the number that actually decides anything — the deadline is the
    /// big figure beside it, and knowing when you have to begin is what the
    /// whole app exists to work out.
    static func startLine(_ item: OnTimeWidgetSnapshot.Upcoming, now: Date) -> String {
        let start = "start \(clock(item.mustStartAt))"
        let calendar = Calendar.current
        if calendar.isDate(item.deadline, inSameDayAs: now) { return start }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(item.deadline, inSameDayAs: tomorrow) {
            return "Tomorrow · \(start)"
        }
        return "\(weekdayFormatter.string(from: item.deadline)) · \(start)"
    }
}

private struct WidgetBackground: ViewModifier {
    @Environment(\.widgetFamily) private var family

    func body(content: Content) -> some View {
        // iOS 17 refuses to draw a widget that has not adopted this API — it
        // renders the system "Please adopt containerBackground" placeholder
        // instead of the view, which looks exactly like a crashed widget. So
        // both branches below apply it; only the fill differs.
        //
        // Lock Screen accessories are drawn in the system's own vibrant
        // material and are tinted by it. Painting one black puts an opaque
        // plate inside the widget's rounded rect, and the white opacities the
        // Home Screen version uses get flattened by the tint anyway — so the
        // accessory family keeps its background clear and its own foreground.
        if family == .accessoryRectangular {
            content.containerBackground(.clear, for: .widget)
        } else {
            content.containerBackground(for: .widget) { Color.black }
        }
    }
}

private extension View {
    func widgetBackground() -> some View {
        modifier(WidgetBackground())
    }
}
