import SwiftUI

/// The pieces every screen is built from.
///
/// The app has one look: true black ground, content as hairline cards, three
/// whites for hierarchy, and colour only where colour is a signal. Before
/// this file existed the Now screen had that look and every other screen was
/// a system `List` or `Form`, which on a forced dark scheme renders grey
/// panels, grey section headers and a cyan tint on every value. These are the
/// Now screen's own rows and labels, lifted out so the rest of the app is
/// built from the same parts rather than resembling them.
///
/// `Shared/OnTimeSpectrum.swift` holds the colours (the widget compiles that
/// too). Everything here is app only.

// MARK: - Type scale

/// The whole type scale, by name, so a row somewhere does not quietly invent
/// a fourth size.
enum InkType {
    static let label = Font.caption.weight(.bold)
    static let labelSmall = Font.caption2.weight(.bold)
    static let hero = Font.system(size: 62, weight: .bold, design: .rounded)
    static let display = Font.system(size: 52, weight: .heavy, design: .rounded)
    static let number = Font.system(size: 30, weight: .bold, design: .rounded)
    static let value = Font.title3.weight(.bold)
    static let rowTitle = Font.body.weight(.semibold)
    static let rowMeta = Font.caption
    static let bodyText = Font.subheadline
    static let buttonProminent = Font.headline
    static let buttonQuiet = Font.subheadline.weight(.semibold)
    static let chip = Font.caption.weight(.bold)
    static let clock = Font.caption.weight(.semibold)
}

// MARK: - Metrics

/// The spacing rhythm, by name for the same reason as the type scale.
enum InkMetric {
    static let page: CGFloat = 20
    static let section: CGFloat = 24
    static let labelToCard: CGFloat = 12
    static let cardToCard: CGFloat = 10
    static let rowPadding: CGFloat = 14
    static let heroPadding: CGFloat = 20
    static let rowMinHeight: CGFloat = 48
    static let radius: CGFloat = 18
    static let innerRadius: CGFloat = 12
}

// MARK: - Labels and titles

/// The section label: the line of small bold uppercase text that sits on the
/// ink above a card, with an optional action at the trailing end of the same
/// row. Every section has one of these. No screen has a large navigation
/// title.
struct SectionLabel<Trailing: View>: View {
    var text: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Text(text)
                .font(InkType.label)
                .tracking(1.5)
                .foregroundStyle(OnTimeSpectrum.secondaryText)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

/// A pushed screen's or a sheet's title, supplied as the principal toolbar
/// item so it reads as a section label rather than as a system navigation
/// title. Callers pass it already uppercased.
struct InkTitle: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(InkType.label)
            .tracking(1.5)
            .foregroundStyle(OnTimeSpectrum.secondaryText)
    }
}

/// The centred caption at the top of a tab root, in `TopBar`'s middle slot.
struct InkBarTitle: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(InkType.label)
            .tracking(2)
            .foregroundStyle(OnTimeSpectrum.secondaryText)
    }
}

/// The top chrome of a tab root: one caption line, no system navigation bar.
/// Extracted from the Now screen so the other three tabs wear the same
/// chrome. Leading and trailing keep the middle centred, so a screen with an
/// action in one corner passes an invisible copy of it into the other.
struct TopBar<Leading: View, Center: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var center: () -> Center
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            leading()
            Spacer()
            center()
            Spacer()
            trailing()
        }
        .padding(.horizontal, InkMetric.page)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

extension TopBar where Leading == EmptyView, Center == InkBarTitle, Trailing == EmptyView {
    init(title: String) {
        self.init(leading: { EmptyView() }, center: { InkBarTitle(title) }, trailing: { EmptyView() })
    }
}

// MARK: - Cards and rows

/// A hairline between two rows of a card, inset from the leading edge so the
/// rows read as one stack rather than as separate plates.
struct InkHairline: View {
    var body: some View {
        Rectangle()
            .fill(OnTimeSpectrum.hairline)
            .frame(height: 1)
            .padding(.leading, InkMetric.rowPadding)
    }
}

/// A card holding a vertical stack of rows, with a hairline between each
/// pair. `_VariadicView` is what makes "between each pair" possible: a plain
/// `VStack` cannot see its own children, so the alternative is every caller
/// interleaving separators by hand and getting one wrong.
struct InkCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(InkCardLayout()) {
            content()
        }
    }
}

private struct InkCardLayout: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                if child.id != children.first?.id {
                    InkHairline()
                }
                child
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .spectrumCard()
    }
}

/// The shape of every row inside a card: 14 all round, at least 48 tall.
struct InkRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(InkMetric.rowPadding)
        .frame(minHeight: InkMetric.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Title on the left, a value on the right. With `chevron` it is the row that
/// opens a picker.
struct InkValueRow: View {
    var title: String
    var value: String
    var valueColor: Color = OnTimeSpectrum.primaryText
    var chevron: Bool = false
    var action: (() -> Void)? = nil

    private var row: some View {
        InkRow {
            Text(title)
                .font(InkType.rowTitle)
                .foregroundStyle(OnTimeSpectrum.primaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(InkType.label)
                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
            }
        }
    }

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }
}

/// Title on the left, a switch on the right. The switch is the system one:
/// the accent is the only colour a `Toggle` can be seen to be wearing, and
/// white makes on and off render identically.
struct InkToggleRow: View {
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        InkRow {
            Text(title)
                .font(InkType.rowTitle)
                .foregroundStyle(OnTimeSpectrum.primaryText)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(OnTimeSpectrum.accent)
        }
    }
}

/// Title, value, and two circles. Not a system `Stepper`: that draws a grey
/// segmented plate that belongs to a `Form`.
struct InkStepperRow: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var unit: String = ""

    private var display: String {
        unit.isEmpty ? "\(value)" : "\(value) \(unit)"
    }

    var body: some View {
        InkRow {
            Text(title)
                .font(InkType.rowTitle)
                .foregroundStyle(OnTimeSpectrum.primaryText)
            Spacer(minLength: 8)
            Text(display)
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(OnTimeSpectrum.primaryText)
            HStack(spacing: 8) {
                circle("minus", enabled: value - step >= range.lowerBound) {
                    value = max(range.lowerBound, value - step)
                }
                circle("plus", enabled: value + step <= range.upperBound) {
                    value = min(range.upperBound, value + step)
                }
            }
        }
    }

    private func circle(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(OnTimeSpectrum.primaryText)
                .frame(width: 32, height: 32)
                .background(Circle().strokeBorder(OnTimeSpectrum.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
    }
}

/// A row that goes somewhere. Wrap it in a `NavigationLink` with
/// `.buttonStyle(.plain)`; the chevron is drawn here rather than by the link,
/// which would draw a system one in the tint.
struct InkNavRow: View {
    var title: String
    var symbol: String? = nil
    var value: String? = nil

    var body: some View {
        InkRow {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                    .frame(width: 24)
            }
            Text(title)
                .font(InkType.rowTitle)
                .foregroundStyle(OnTimeSpectrum.primaryText)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(InkType.value)
                    .monospacedDigit()
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            }
            Image(systemName: "chevron.right")
                .font(InkType.label)
                .foregroundStyle(OnTimeSpectrum.tertiaryText)
        }
    }
}

/// A row that is a button: its whole width is the tap target and the text is
/// centred. Destructive ones are `late`.
struct InkButtonRow: View {
    var title: String
    var role: ButtonRole? = nil
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            InkRow {
                Spacer(minLength: 0)
                Text(title)
                    .font(InkType.buttonQuiet)
                    .foregroundStyle(role == .destructive ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
    }
}

/// A text field as a row of a card. No border of its own: the card is the
/// border.
struct InkTextRow: View {
    var placeholder: String
    @Binding var text: String
    var autocapitalization: TextInputAutocapitalization = .sentences
    var lineLimit: ClosedRange<Int>? = nil

    var body: some View {
        InkRow {
            Group {
                if let lineLimit {
                    // Only a field that is allowed to wrap gets the vertical
                    // axis. A single line field on that axis truncates
                    // instead of scrolling as you type past the width.
                    TextField("", text: $text, prompt: prompt, axis: .vertical)
                        .lineLimit(lineLimit)
                } else {
                    TextField("", text: $text, prompt: prompt)
                }
            }
            .font(.body)
            .foregroundStyle(OnTimeSpectrum.primaryText)
            .tint(OnTimeSpectrum.primaryText)
            .textInputAutocapitalization(autocapitalization)
        }
    }

    private var prompt: Text {
        Text(placeholder).foregroundColor(OnTimeSpectrum.tertiaryText)
    }
}

/// A row of plain text inside a card: a note, a warning, a summary line.
struct InkTextLine: View {
    var text: String
    var color: Color = OnTimeSpectrum.tertiaryText
    var font: Font = InkType.rowMeta

    var body: some View {
        InkRow {
            Text(text)
                .font(font)
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
    }
}

/// What a screen shows instead of rows when there are none. Replaces every
/// `ContentUnavailableView`, which draws a centred grey glyph, a title and a
/// paragraph of explanation.
struct InkEmpty: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(InkType.bodyText)
            .foregroundStyle(OnTimeSpectrum.tertiaryText)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .spectrumCard()
    }
}

// MARK: - Small controls

/// The "+" that adds a row to the section its label sits above.
struct PlusButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.headline)
                .foregroundStyle(OnTimeSpectrum.primaryText)
                .padding(9)
                .background(Circle().strokeBorder(OnTimeSpectrum.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A capsule chip. Filled ones carry a value; outlined ones are the Add
/// affordance beside a row of them.
struct Chip: View {
    enum Style { case filled, outlined, selected }

    var text: String
    var systemImage: String? = nil
    var style: Style = .filled

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(InkType.chip)
        .foregroundStyle(style == .selected ? OnTimeSpectrum.ink : OnTimeSpectrum.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            switch style {
            case .filled:
                Capsule().fill(OnTimeSpectrum.surface)
                    .overlay(Capsule().strokeBorder(OnTimeSpectrum.hairline))
            case .outlined:
                Capsule().strokeBorder(OnTimeSpectrum.edge, lineWidth: 1)
            case .selected:
                Capsule().fill(OnTimeSpectrum.primaryText)
            }
        }
    }
}

/// One option of a `ChipPicker`.
struct ChipOption<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var id: Value { value }

    init(_ value: Value, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// The app's picker: a row of chips, the selected one filled white. Replaces
/// every system `Picker`, which renders as a grey menu button with a cyan
/// value.
struct ChipPicker<Value: Hashable>: View {
    var options: [ChipOption<Value>]
    @Binding var selection: Value

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        Chip(text: option.label,
                             style: option.value == selection ? .selected : .filled)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Seven equal chips, one per weekday. Never lets the set empty out: a
/// routine with no days has no next occurrence and would vanish from the
/// schedule with nothing on screen saying why.
struct WeekdayChips: View {
    @Binding var weekdays: Set<Int>

    private var symbols: [String] { Calendar.current.veryShortWeekdaySymbols }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let on = weekdays.contains(day)
                Button {
                    if on, weekdays.count > 1 {
                        weekdays.remove(day)
                    } else if !on {
                        weekdays.insert(day)
                    }
                } label: {
                    Text(symbols.indices.contains(day - 1) ? symbols[day - 1] : "?")
                        .font(InkType.chip)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: InkMetric.innerRadius, style: .continuous)
                                    .fill(OnTimeSpectrum.primaryText)
                            } else {
                                RoundedRectangle(cornerRadius: InkMetric.innerRadius, style: .continuous)
                                    .fill(OnTimeSpectrum.surface)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: InkMetric.innerRadius, style: .continuous)
                                            .strokeBorder(OnTimeSpectrum.hairline, lineWidth: 1)
                                    }
                            }
                        }
                        .foregroundStyle(on ? OnTimeSpectrum.ink : OnTimeSpectrum.primaryText)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Step rows

/// Where a step sits relative to the run: not reached, happening now, over.
enum StepRowState {
    case upcoming, current, done
}

/// One step of a sequence, as a card. The composer, the routine editor and
/// the run screen all draw the same row: a symbol in a fixed column, the
/// name, a meta line, whatever the screen wants on the right, and a rail at
/// the leading edge saying where the step is in the run.
///
/// Colour on it is a signal and nothing else. The rail used to take a hue
/// from the step's index, which drew the first step of every sequence in the
/// exact red this app reserves for running late.
struct StepRowCard<Trailing: View>: View {
    var symbol: String
    var name: String
    var meta: [String] = []
    var state: StepRowState = .upcoming
    /// A problem with this step, shown under the meta line in `late`.
    var problem: String? = nil
    var onDelete: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    private var symbolColor: Color {
        switch state {
        case .upcoming: return OnTimeSpectrum.secondaryText
        case .current: return OnTimeSpectrum.primaryText
        case .done: return OnTimeSpectrum.done
        }
    }

    private var nameColor: Color {
        state == .done ? OnTimeSpectrum.secondaryText : OnTimeSpectrum.primaryText
    }

    private var railColor: Color {
        switch state {
        case .upcoming: return Color.white.opacity(0.18)
        case .current: return Color.white.opacity(0.85)
        case .done: return OnTimeSpectrum.done.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(InkType.rowTitle)
                    .foregroundStyle(nameColor)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(InkType.rowMeta)
                        .foregroundStyle(OnTimeSpectrum.tertiaryText)
                }
                if let problem {
                    Text(problem)
                        .font(.caption2)
                        .foregroundStyle(OnTimeSpectrum.late)
                }
            }

            Spacer()

            trailing()

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
        .spectrumCard(highlighted: state == .current)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(railColor)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
    }
}

extension StepRowCard where Trailing == EmptyView {
    init(symbol: String,
         name: String,
         meta: [String] = [],
         state: StepRowState = .upcoming,
         problem: String? = nil,
         onDelete: (() -> Void)? = nil) {
        self.init(symbol: symbol, name: name, meta: meta, state: state,
                  problem: problem, onDelete: onDelete) { EmptyView() }
    }
}

/// The trailing slot most step rows want: a number in `value` style.
struct StepRowValue: View {
    var text: String
    var color: Color = OnTimeSpectrum.primaryText
    var caption: String? = nil
    var captionColor: Color = OnTimeSpectrum.tertiaryText

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(text)
                .font(InkType.value)
                .monospacedDigit()
                .foregroundStyle(color)
            if let caption {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(captionColor)
            }
        }
    }
}

// MARK: - Modifiers

extension View {
    /// A `List` stripped down to nothing, for the two screens that need
    /// `swipeActions`. Rows inside it are cards, so the result is
    /// indistinguishable from a `ScrollView` of cards.
    func inkList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .spectrumBackground()
    }

    /// The row treatment that goes with `inkList()`, applied to each row.
    func inkListRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: InkMetric.page,
                                      bottom: 5, trailing: InkMetric.page))
    }

    /// A pushed screen's or a sheet's navigation bar: black, hairline, and a
    /// section label where the system would put a title.
    func inkNavigation(title: String) -> some View {
        self
            .spectrumBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(OnTimeSpectrum.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { InkTitle(title) }
            }
    }

    /// A toolbar text button: white, or `late` when it destroys something.
    func inkToolbarButton(destructive: Bool = false) -> some View {
        self
            .font(InkType.buttonQuiet)
            .foregroundStyle(destructive ? OnTimeSpectrum.late : OnTimeSpectrum.primaryText)
    }
}
