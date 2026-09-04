import SwiftUI

/// A full-screen replacement for the tiny `.compact` `DatePicker` popover —
/// tap the big time to open this instead of a nugget-sized wheel. Two modes:
/// clock time (`.time`, hour/minute/AM-PM wheel) for things like "Final
/// Time," and a plain minute count (`.duration`) for step lengths. Both
/// support typing the value directly via the keyboard button, since a wheel
/// is fast for small nudges but slow for "I know it's 2:47."
struct FullScreenTimePicker: View {
    enum Mode {
        case time
        case duration
    }

    let title: String
    let mode: Mode
    /// Only used in `.time` mode.
    @Binding var date: Date
    /// Only used in `.duration` mode.
    @Binding var minutes: Int
    /// Called right before dismissing, once the typed/wheel value is
    /// committed — for callers where "Done" also needs to do something
    /// (e.g. insert a new step) rather than just close the sheet.
    var onDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isTyping = false
    @State private var typedText = ""
    @FocusState private var typedFieldFocused: Bool

    /// The value being edited, committed to the caller's binding only on
    /// Done. The wheel used to write through the live binding on every
    /// detent, so "Cancel" (and swiping the sheet down) left the deadline
    /// or a routine's anchor already changed — Cancel didn't cancel.
    @State private var workingDate: Date
    @State private var workingMinutes: Int

    init(title: String, date: Binding<Date>, onDone: (() -> Void)? = nil) {
        self.title = title
        self.mode = .time
        self._date = date
        self._minutes = .constant(0)
        self.onDone = onDone
        self._workingDate = State(initialValue: date.wrappedValue)
        self._workingMinutes = State(initialValue: 0)
    }

    init(title: String, minutes: Binding<Int>, onDone: (() -> Void)? = nil) {
        self.title = title
        self.mode = .duration
        self._date = .constant(Date())
        self._minutes = minutes
        self.onDone = onDone
        self._workingDate = State(initialValue: Date())
        self._workingMinutes = State(initialValue: minutes.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                if isTyping {
                    typedEntry
                } else {
                    bigDisplay
                    wheel
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inkNavigation(title: title.uppercased())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .inkToolbarButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginTyping()
                    } label: {
                        Image(systemName: isTyping ? "dial.min" : "keyboard")
                            .foregroundStyle(OnTimeSpectrum.primaryText)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitTypedIfNeeded()
                        switch mode {
                        case .time: date = workingDate
                        case .duration: minutes = workingMinutes
                        }
                        onDone?()
                        dismiss()
                    }
                    .inkToolbarButton()
                }
            }
        }
    }

    // MARK: - Big display

    private var bigDisplay: some View {
        Text(mode == .time ? timeString : durationString)
            .font(.system(size: 64, weight: .heavy, design: .rounded))
            .monospacedDigit()
            // Explicitly white, not `Color.accentColor`. The accent *asset*
            // and the environment `.tint` are two different values, and this
            // view is presented as a sheet — so the number rendered in the
            // asset's blue while the toolbar beside it rendered in the tint,
            // and the two resolved a frame apart, which looked like the digits
            // starting white and then turning blue on their own.
            .foregroundStyle(OnTimeSpectrum.primaryText)
            .contentTransition(.numericText())
            .animation(.default, value: mode == .time ? workingDate : Date(timeIntervalSince1970: TimeInterval(workingMinutes)))
            .padding(.bottom, 24)
    }

    // MARK: - Wheel

    @ViewBuilder
    private var wheel: some View {
        switch mode {
        case .time:
            VStack(spacing: 16) {
                DatePicker("", selection: $workingDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .colorScheme(.dark)

                // Same drag-to-scrub feel as the duration picker's "+" flow
                // (`DurationScrubber`), for nudging the time a few minutes
                // without spinning the wheel.
                ScrubTrack(
                    value: minutesSinceMidnightBinding,
                    range: 0...1439,
                    scrubWindow: 90,
                    pointsPerValue: 6
                ) { target in
                    beginTyping(prefilledMinutesSinceMidnight: target)
                }
                .padding(.horizontal)
            }
        case .duration:
            DurationScrubber(minutes: $workingMinutes, range: 1...600)
                .padding(.horizontal)
        }
    }

    /// `workingDate` reduced to minutes since midnight, for the scrub track
    /// above — which only knows how to scrub a bare `Int`, not a `Date`.
    private var minutesSinceMidnightBinding: Binding<Int> {
        Binding(
            get: {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: workingDate)
                return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            },
            set: { newValue in
                let clamped = newValue.clamped(to: 0...1439)
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: workingDate)
                comps.hour = clamped / 60
                comps.minute = clamped % 60
                workingDate = Calendar.current.date(from: comps) ?? workingDate
            }
        )
    }

    // MARK: - Typed entry

    private var typedEntry: some View {
        TextField("", text: $typedText, prompt: Text(mode == .time ? "h:mm am/pm" : "minutes")
            .foregroundColor(OnTimeSpectrum.tertiaryText))
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .foregroundStyle(OnTimeSpectrum.primaryText)
            .tint(OnTimeSpectrum.primaryText)
            .multilineTextAlignment(.center)
            .keyboardType(mode == .time ? .default : .numberPad)
            .focused($typedFieldFocused)
            .textFieldStyle(.plain)
            .padding()
            .background(OnTimeSpectrum.surface)
            .clipShape(RoundedRectangle(cornerRadius: InkMetric.innerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: InkMetric.innerRadius, style: .continuous)
                    .strokeBorder(OnTimeSpectrum.hairline, lineWidth: 1)
            }
        .padding(.horizontal, 32)
        .onAppear {
            typedText = mode == .time ? timeString : "\(workingMinutes)"
            typedFieldFocused = true
        }
    }

    private func beginTyping() {
        if isTyping {
            commitTypedIfNeeded()
        }
        isTyping.toggle()
    }

    /// The scrub track's drag-past-window handoff: it hands back a target
    /// in minutes-since-midnight, not a formatted string, so this converts
    /// before dropping into the same typed-entry mode the keyboard button
    /// opens.
    private func beginTyping(prefilledMinutesSinceMidnight minutes: Int) {
        let clamped = minutes.clamped(to: 0...1439)
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: workingDate)
        comps.hour = clamped / 60
        comps.minute = clamped % 60
        if let target = Calendar.current.date(from: comps) {
            typedText = TimeFormatting.clockString(target)
        }
        isTyping = true
    }

    private func commitTypedIfNeeded() {
        guard isTyping else { return }
        switch mode {
        case .time:
            if let parsed = Self.parseTime(typedText) {
                workingDate = parsed
            }
        case .duration:
            if let value = Int(typedText.trimmingCharacters(in: .whitespaces)), value > 0 {
                workingMinutes = min(value, 600)
            }
        }
    }

    // MARK: - Formatting

    private var timeString: String {
        TimeFormatting.clockString(workingDate)
    }

    private var durationString: String {
        "\(workingMinutes) min"
    }

    /// Accepts "2:47 PM", "2:47pm", "14:47", "2 pm" — loose enough that
    /// typing fast on a phone keyboard still lands. Parsed against a fixed
    /// POSIX locale: the device locale's formatter can reject "PM" outright
    /// (24 hour locales) and the failure was silent, the typed entry just
    /// ignored. Internal, not private, so the format list is testable.
    static func parseTime(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formats = ["h:mm a", "h:mma", "HH:mm", "h a", "ha"]
        for format in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let parsedTime = f.date(from: trimmed) {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                let timeComps = Calendar.current.dateComponents([.hour, .minute], from: parsedTime)
                comps.hour = timeComps.hour
                comps.minute = timeComps.minute
                return Calendar.current.date(from: comps)
            }
        }
        return nil
    }
}
