import Foundation

/// Converts a time-of-day (e.g. "Iqama 19:30") into an absolute `Date`
/// relative to `now`.
///
/// The old HTML prototype (`time app.html`) rolled the deadline to tomorrow
/// whenever the *required start time* (deadline minus prep) was already in
/// the past — so with the deadline 4 minutes away and 7 minutes of prep, it
/// reported ~23 hours left instead of "you're 3 minutes late." That is
/// wrong: a start time in the past just means you're already late for a
/// deadline that hasn't happened yet, which is a lateness case, not a
/// tomorrow case.
///
/// The only thing that determines whether to roll to tomorrow is whether
/// the **deadline itself** has already passed.
enum DeadlineResolver {
    /// Resolves `hour:minute` to the next occurrence of that time — today if
    /// it hasn't happened yet, tomorrow if it has. Never looks at prep time
    /// or any required start time; those are the solver's concern, and
    /// lateness must surface as lateness, not as a shifted deadline.
    static func resolve(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let candidate = calendar.date(from: components) else {
            // Should be unreachable for valid hour/minute input; fall back
            // to `now` rather than crashing on a malformed calendar.
            return now
        }

        if candidate < now {
            return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }
}
