import SwiftUI
import SwiftData

/// The work clock: one running session at a time, what you have already
/// logged today, and the way through to the week.
///
/// Deliberately not built on `RunEngine` or a Live Activity. A run is a
/// solved sequence of steps with leave by times to hold you to; a work
/// session is one start time and one end time, and the only live thing
/// about it is a number counting up. Everything that makes a run
/// complicated would be dead weight here.
struct WorkView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// Every session, newest first, filtered in memory rather than by a
    /// `#Predicate` on today's bounds: a date predicate would have to be
    /// rebuilt as the day rolls over, and a few hundred rows a year is not
    /// a fetch worth optimising.
    @Query(sort: \WorkSession.startedAt, order: .reverse)
    private var sessions: [WorkSession]

    @State private var now = Date()
    @State private var editing: WorkSessionEditor.Target?
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TopBar {
                    PlusButton {}
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } center: {
                    InkBarTitle("Work")
                } trailing: {
                    PlusButton { editing = .new(day: Date()) }
                        .accessibilityLabel("Add session by hand")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: InkMetric.section) {
                        clockFace
                        todaySection
                        InkCard {
                            NavigationLink {
                                WorkWeekView()
                            } label: {
                                InkNavRow(title: "This week", symbol: "calendar")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, InkMetric.page)
                    .padding(.bottom, InkMetric.section)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .spectrumBackground()
            .toolbar(.hidden, for: .navigationBar)
            .onReceive(ticker) { tick in
                // Only while something is counting: a once a second state
                // write with nothing on screen changing is a rebuild of the
                // whole list for no reason.
                if runningSession != nil { now = tick }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                now = Date()
                // Repairs the impossible but not unreachable two open
                // sessions case on the way back in. See `WorkClock`.
                WorkClock.openSession(in: modelContext)
            }
            .task {
                now = Date()
                WorkClock.openSession(in: modelContext)
            }
            .sheet(item: $editing) { target in
                WorkSessionEditor(target: target)
            }
        }
    }

    private var clockFace: some View {
        VStack(spacing: 16) {
            Text(WorkHours.stopwatchString(runningSession?.seconds(now: now) ?? 0))
                .onTimeNumeral(InkType.heroSize)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(runningSession == nil ? OnTimeSpectrum.tertiaryText : OnTimeSpectrum.primaryText)
                .contentTransition(.numericText())

            Text(runningSession.map { "Started \(TimeFormatting.clockString($0.startedAt))" } ?? "Off the clock")
                .font(InkType.bodyText)
                .foregroundStyle(OnTimeSpectrum.secondaryText)

            if runningSession == nil {
                Button {
                    WorkClock.start(in: modelContext)
                    now = Date()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(SpectrumButtonStyle())
            } else {
                Button {
                    WorkClock.stop(in: modelContext)
                    now = Date()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(SpectrumButtonStyle())
            }
        }
        .padding(InkMetric.heroPadding)
        .frame(maxWidth: .infinity)
        .spectrumCard()
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel(text: "Today") {
                Text(WorkHours.clockString(todaysSeconds))
                    .font(InkType.clock)
                    .monospacedDigit()
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
            }

            if todaysSessions.isEmpty {
                InkEmpty("Nothing logged.")
            } else {
                VStack(spacing: InkMetric.cardToCard) {
                    ForEach(todaysSessions) { session in
                        Button {
                            editing = .existing(session)
                        } label: {
                            WorkSessionRow(session: session, now: now) {
                                WorkClock.delete(session, in: modelContext)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var runningSession: WorkSession? {
        sessions.first { $0.isRunning }
    }

    /// Sessions with any part of them on today, so an overnight shift shows
    /// on both days it touches, matching how the week view counts it.
    private var todaysSessions: [WorkSession] {
        let dayStart = Calendar.current.startOfDay(for: now)
        return sessions.filter {
            WorkHours.seconds(of: $0.interval(now: now), withinDayStarting: dayStart) > 0 || $0.isRunning
        }
    }

    private var todaysSeconds: TimeInterval {
        let dayStart = Calendar.current.startOfDay(for: now)
        return sessions.reduce(0) {
            $0 + WorkHours.seconds(of: $1.interval(now: now), withinDayStarting: dayStart)
        }
    }
}

/// One session as a card. Shared by the day list on this screen and the day
/// detail inside the week view, so an edit affordance never appears in one
/// place and not the other.
struct WorkSessionRow: View {
    let session: WorkSession
    let now: Date
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(spanLabel)
                    .font(InkType.rowTitle)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
                if !session.note.isEmpty {
                    Text(session.note)
                        .font(InkType.rowMeta)
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                } else if session.wasEnteredManually {
                    Text("By hand")
                        .font(InkType.rowMeta)
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                }
            }

            Spacer()

            Text(WorkHours.clockString(session.seconds(now: now)))
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(session.isRunning ? OnTimeSpectrum.done : OnTimeSpectrum.primaryText)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(InkType.label)
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
        .padding(InkMetric.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectrumCard()
    }

    private var spanLabel: String {
        let start = TimeFormatting.clockString(session.startedAt)
        guard let end = session.endedAt else { return "\(start) to now" }
        return "\(start) to \(TimeFormatting.clockString(end))"
    }
}
