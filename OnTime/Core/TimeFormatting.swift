import Foundation

/// One cached, locale-honoring clock formatter for every screen.
///
/// Six views and two services each built their own `DateFormatter` with a
/// hardcoded "h:mm a" — allocated per call, several of them on a
/// once-per-second render path, and every one of them ignoring the device's
/// 24 hour clock setting. `timeStyle = .short` follows the user's locale
/// and clock preference; the hour-and-minute overload also fixes the chips
/// that used to render "5:30" with no AM or PM.
///
/// `DateFormatter` is not thread safe; every caller here is main-thread UI
/// or notification copy built on the main actor.
enum TimeFormatting {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func clockString(_ date: Date) -> String {
        clock.string(from: date)
    }

    static func clockString(hour: Int, minute: Int, calendar: Calendar = .current) -> String {
        var comps = calendar.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        guard let date = calendar.date(from: comps) else {
            return String(format: "%d:%02d", hour, minute)
        }
        return clockString(date)
    }

    /// A countdown, in the shape a clock face uses: `m:ss` under an hour,
    /// `h:mm:ss` over it. Never negative — a caller past its target says so
    /// with a sign and a colour of its own rather than a minus buried in the
    /// digits, which is unreadable at a glance and was the whole problem
    /// with the old Live Activity number.
    static func countdownString(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// A countdown sized to fit inside a ring: `m:ss` under an hour, and
    /// `23h 57m` above it rather than `23:57:35`.
    ///
    /// Seconds stop being information long before they stop taking up room.
    /// The full `h:mm:ss` form is eight characters wide, which overflowed the
    /// ring on a nearly-day-long span and wrapped onto a second line mid
    /// number ("23:57:3" above a lone "5"). Above an hour nobody is reading
    /// the seconds anyway, so they go, and the number gets narrow enough to
    /// sit on one line at any span.
    static func compactCountdownString(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0).rounded())
        guard total >= 3600 else { return countdownString(interval) }
        let h = total / 3600
        let m = (total % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    /// A span in words, for captions rather than counters: "1 hr 5 min".
    static func spanWords(_ interval: TimeInterval) -> String {
        let minutes = Int((max(interval, 0) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m > 0 ? "\(h) hr \(m) min" : "\(h) hr"
    }

    // MARK: Dates

    /// "Monday". Full weekday name for the week view's day rows.
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    /// "Aug 24". Month and day, no year, for row subtitles and the week
    /// range label where the year is never in question.
    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static func weekdayString(_ date: Date) -> String {
        weekday.string(from: date)
    }

    static func monthDayString(_ date: Date) -> String {
        monthDay.string(from: date)
    }

    /// "Aug 24 to Aug 30", written out rather than hyphenated so it reads
    /// the same way it would be said.
    static func dayRangeString(from start: Date, to end: Date) -> String {
        "\(monthDayString(start)) to \(monthDayString(end))"
    }
}
