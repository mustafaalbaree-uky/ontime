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

    init(title: String, date: Binding<Date>, onDone: (() -> Void)? = nil) {
        self.title = title
        self.mode = .time
        self._date = date
        self._minutes = .constant(0)
        self.onDone = onDone
    }

    init(title: String, minutes: Binding<Int>, onDone: (() -> Void)? = nil) {
        self.title = title
        self.mode = .duration
        self._date = .constant(Date())
        self._minutes = minutes
        self.onDone = onDone
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginTyping()
                    } label: {
                        Image(systemName: isTyping ? "dial.min" : "keyboard")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitTypedIfNeeded()
                        onDone?()
                        dismiss()
                    }
                    .font(.headline)
                }
            }
        }
    }

    // MARK: - Big display

    private var bigDisplay: some View {
        Text(mode == .time ? timeString : durationString)
            .font(.system(size: 64, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .contentTransition(.numericText())
            .animation(.default, value: mode == .time ? date : Date(timeIntervalSince1970: TimeInterval(minutes)))
            .padding(.bottom, 24)
    }

    // MARK: - Wheel

    @ViewBuilder
    private var wheel: some View {
        switch mode {
        case .time:
            VStack(spacing: 16) {
                DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()

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
            DurationScrubber(minutes: $minutes, range: 1...600)
                .padding(.horizontal)
        }
    }

    /// `date` reduced to minutes since midnight, for the scrub track above —
    /// which only knows how to scrub a bare `Int`, not a `Date`.
    private var minutesSinceMidnightBinding: Binding<Int> {
        Binding(
            get: {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            },
            set: { newValue in
                let clamped = newValue.clamped(to: 0...1439)
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
                comps.hour = clamped / 60
                comps.minute = clamped % 60
                date = Calendar.current.date(from: comps) ?? date
            }
        )
    }

    // MARK: - Typed entry

    private var typedEntry: some View {
        VStack(spacing: 16) {
            TextField(mode == .time ? "h:mm am/pm" : "minutes", text: $typedText)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .keyboardType(mode == .time ? .default : .numberPad)
                .focused($typedFieldFocused)
                .textFieldStyle(.plain)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(mode == .time ? "e.g. 2:47 PM" : "e.g. 25")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .onAppear {
            typedText = mode == .time ? timeString : "\(minutes)"
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
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = clamped / 60
        comps.minute = clamped % 60
        if let target = Calendar.current.date(from: comps) {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            typedText = f.string(from: target)
        }
        isTyping = true
    }

    private func commitTypedIfNeeded() {
        guard isTyping else { return }
        switch mode {
        case .time:
            if let parsed = Self.parseTime(typedText) {
                date = parsed
            }
        case .duration:
            if let value = Int(typedText.trimmingCharacters(in: .whitespaces)), value > 0 {
                minutes = min(value, 600)
            }
        }
    }

    // MARK: - Formatting

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private var durationString: String {
        "\(minutes) min"
    }

    /// Accepts "2:47 PM", "2:47pm", "14:47", "247pm" — loose enough that
    /// typing fast on a phone keyboard still lands.
    private static func parseTime(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formats = ["h:mm a", "h:mma", "HH:mm", "h a", "ha"]
        for format in formats {
            let f = DateFormatter()
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
