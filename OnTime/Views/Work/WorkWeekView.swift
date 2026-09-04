import SwiftUI
import SwiftData

/// One week of work, a row per day, with the two totals that matter: what
/// you actually worked, and what goes on the timesheet.
///
/// The week runs from whatever the device calls the first day of the week
/// rather than a day picked here, so it lines up with every other calendar
/// on the phone. Paging back is unbounded; paging forward stops at the
/// current week, since there is nothing to see past it.
struct WorkWeekView: View {
    @Query(sort: \WorkSession.startedAt) private var sessions: [WorkSession]

    @State private var weekStart: Date = WorkHours.weekStart(containing: Date())
    @State private var now = Date()
    /// Half a minute is plenty: these rows are shown to the minute, and the
    /// only live number on the screen is a running session's contribution.
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InkMetric.section) {
                weekHeader

                InkCard {
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        NavigationLink {
                            WorkDayView(day: day)
                        } label: {
                            DayRow(day: day,
                                   seconds: dailySeconds[index],
                                   isToday: calendar.isDateInToday(day))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
                    SectionLabel("WEEK")
                    InkCard {
                        InkValueRow(title: "Worked", value: WorkHours.clockString(weekSeconds))
                        InkValueRow(title: "Decimal",
                                    value: "\(WorkHours.decimalHoursString(weekSeconds)) h",
                                    valueColor: OnTimeSpectrum.secondaryText)
                        InkRow {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Timesheet")
                                    .font(InkType.rowTitle)
                                    .foregroundStyle(OnTimeSpectrum.primaryText)
                                Text("quarter hour")
                                    .font(InkType.rowMeta)
                                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
                            }
                            Spacer(minLength: 8)
                            Text("\(WorkHours.decimalHoursString(roundedWeekSeconds)) h")
                                .font(InkType.value)
                                .monospacedDigit()
                                .foregroundStyle(OnTimeSpectrum.primaryText)
                        }
                    }
                }
            }
            .padding(.horizontal, InkMetric.page)
            .padding(.top, InkMetric.labelToCard)
            .padding(.bottom, InkMetric.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .inkNavigation(title: "WEEK")
        .onReceive(ticker) { now = $0 }
    }

    private var weekHeader: some View {
        HStack {
            Button {
                weekStart = WorkHours.weekStart(offsetBy: -1, from: weekStart, calendar: calendar)
            } label: {
                Image(systemName: "chevron.left")
                    .font(InkType.label)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous week")

            Spacer()

            Text(rangeLabel)
                .font(InkType.rowTitle)
                .foregroundStyle(OnTimeSpectrum.primaryText)

            Spacer()

            Button {
                weekStart = WorkHours.weekStart(offsetBy: 1, from: weekStart, calendar: calendar)
            } label: {
                Image(systemName: "chevron.right")
                    .font(InkType.label)
                    .foregroundStyle(OnTimeSpectrum.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(isCurrentWeek)
            .opacity(isCurrentWeek ? 0.38 : 1)
            .accessibilityLabel("Next week")
        }
    }

    private var days: [Date] {
        WorkHours.days(inWeekStarting: weekStart, calendar: calendar)
    }

    private var intervals: [WorkInterval] {
        sessions.map { $0.interval(now: now) }
    }

    private var dailySeconds: [TimeInterval] {
        WorkHours.dailySeconds(intervals: intervals, days: days, calendar: calendar)
    }

    private var weekSeconds: TimeInterval {
        dailySeconds.reduce(0, +)
    }

    private var roundedWeekSeconds: TimeInterval {
        WorkHours.roundedToQuarterHour(weekSeconds)
    }

    private var isCurrentWeek: Bool {
        weekStart >= WorkHours.weekStart(containing: now, calendar: calendar)
    }

    private var rangeLabel: String {
        if isCurrentWeek { return "This week" }
        guard let last = days.last else { return "" }
        return TimeFormatting.dayRangeString(from: weekStart, to: last)
    }
}

private struct DayRow: View {
    let day: Date
    let seconds: TimeInterval
    let isToday: Bool

    var body: some View {
        InkRow {
            VStack(alignment: .leading, spacing: 3) {
                Text(TimeFormatting.weekdayString(day))
                    .font(InkType.rowTitle)
                    .foregroundStyle(isToday ? OnTimeSpectrum.primaryText : OnTimeSpectrum.secondaryText)
                Text(TimeFormatting.monthDayString(day))
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
            }

            Spacer(minLength: 8)

            Text(seconds > 0 ? WorkHours.clockString(seconds) : "0:00")
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(seconds > 0 ? OnTimeSpectrum.primaryText : OnTimeSpectrum.tertiaryText)

            Image(systemName: "chevron.right")
                .font(InkType.label)
                .foregroundStyle(OnTimeSpectrum.tertiaryText)
        }
    }
}

/// The sessions behind one day's number, editable and deletable. This is
/// where a day you got wrong actually gets fixed, since the Work screen
/// only ever shows today.
private struct WorkDayView: View {
    let day: Date

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkSession.startedAt) private var sessions: [WorkSession]

    @State private var now = Date()
    @State private var editing: WorkSessionEditor.Target?
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
                // A session that crosses midnight is listed on both days it
                // touches, so a row's own length and the day's total
                // legitimately differ.
                SectionLabel(text: "THIS DAY") {
                    Text(WorkHours.clockString(daySeconds))
                        .font(InkType.clock)
                        .monospacedDigit()
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                }

                if daysSessions.isEmpty {
                    InkEmpty("Nothing logged.")
                } else {
                    VStack(spacing: InkMetric.cardToCard) {
                        ForEach(daysSessions) { session in
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
            .padding(.horizontal, InkMetric.page)
            .padding(.top, InkMetric.labelToCard)
            .padding(.bottom, InkMetric.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .inkNavigation(title: TimeFormatting.monthDayString(day).uppercased())
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                PlusButton { editing = .new(day: day) }
                    .accessibilityLabel("Add session by hand")
            }
        }
        .onReceive(ticker) { now = $0 }
        .sheet(item: $editing) { target in
            WorkSessionEditor(target: target)
        }
    }

    private var dayStart: Date { calendar.startOfDay(for: day) }

    private var daysSessions: [WorkSession] {
        sessions.filter {
            WorkHours.seconds(of: $0.interval(now: now), withinDayStarting: dayStart, calendar: calendar) > 0
        }
    }

    private var daySeconds: TimeInterval {
        sessions.reduce(0) {
            $0 + WorkHours.seconds(of: $1.interval(now: now), withinDayStarting: dayStart, calendar: calendar)
        }
    }
}
