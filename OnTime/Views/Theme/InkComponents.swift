import SwiftUI

/// The pieces every screen is built from.
///
/// The app has one look: true black ground, content as filled cards with no
/// outline, three whites for hierarchy, and colour only where colour is a
/// signal. Before this file existed the Now screen had its own look and every
/// other screen was a system `List` or `Form`, which on a forced dark scheme
/// renders grey panels, grey section headers and a cyan tint on every value.
/// These are the Now screen's own rows and labels, lifted out so the rest of
/// the app is built from the same parts rather than resembling them.
///
/// The type and the shapes are look A, "Instrument", picked from three
/// mockups on 21 Sep 2026. The look before it was SF Rounded in bold and
/// heavy, an outline on every box, 18 pt corners, circles and capsules, and
/// tracked capital labels; the owner called it a toy. So: SF Pro, regular
/// weight, medium at the very most, thin large numerals, sentence case, 10 pt
/// corners, and a fill where there used to be a stroke.
///
/// `Shared/OnTimeSpectrum.swift` holds the colours (the widget compiles that
/// too). Everything here is app only.

// MARK: - Type scale

/// The whole type scale, by name, so a row somewhere does not quietly invent
/// a fourth size. Everything is SF Pro at regular weight; the one medium is
/// the text of a primary button. Nothing is bold, nothing is rounded.
///
/// Text styles rather than fixed sizes, so Dynamic Type still works: footnote
/// is 13 pt, subheadline 15, callout 16 at the default setting.
enum InkType {
    /// Section labels, toolbar actions beside them, chevrons.
    static let label = Font.footnote
    /// The caption over a number inside a card.
    static let labelSmall = Font.caption
    /// A pushed screen's title and a tab root's top bar.
    static let title = Font.callout
    static let value = Font.callout
    static let rowTitle = Font.callout
    static let rowMeta = Font.footnote
    static let bodyText = Font.subheadline
    static let buttonProminent = Font.callout.weight(.medium)
    static let buttonQuiet = Font.subheadline
    static let chip = Font.footnote
    static let clock = Font.footnote

    /// The three numeral sizes. A number takes one through
    /// `onTimeNumeral(_:)` (in `Shared/OnTimeSpectrum.swift`, so the widget
    /// sets its numbers by the same rule), which picks thin for the two large
    /// ones and light for `numberSize`, and tightens the tracking.
    static let heroSize: CGFloat = 62
    static let displaySize: CGFloat = 52
    static let numberSize: CGFloat = 30
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
    /// Cards and buttons.
    static let radius: CGFloat = 10
    /// Anything that sits inside a card.
    static let innerRadius: CGFloat = 8
    /// Step pips and the step strip: one height, whichever step is current.
    static let pipHeight: CGFloat = 3
}

// MARK: - Environment

private struct InkOnCardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for anything drawn inside a card. `spectrumCard` sets it. A chip
    /// or a step row reads it to pick its fill: `surface` on the black ground,
    /// `surfaceRaised` on a card, where `surface` on `surface` would vanish.
    var inkOnCard: Bool {
        get { self[InkOnCardKey.self] }
        set { self[InkOnCardKey.self] = newValue }
    }
}

// MARK: - Labels and titles

/// The section label: the line of small sentence case text that sits on the
/// ink above a card, with an optional action at the trailing end of the same
/// row. Every section has one of these. No screen has a large navigation
/// title. Callers pass it in sentence case ("Final time"); it used to be bold,
/// uppercase and tracked, which was the loudest part of the old look.
struct SectionLabel<Trailing: View>: View {
    var text: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Text(text)
                .font(InkType.label)
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
/// item so it is set in the app's own type rather than as a system navigation
/// title, which is semibold. Callers pass it in sentence case, and a name the
/// user typed exactly as typed.
struct InkTitle: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(InkType.title)
            .foregroundStyle(OnTimeSpectrum.primaryText)
            .lineLimit(1)
    }
}

/// The centred caption at the top of a tab root, in `TopBar`'s middle slot.
struct InkBarTitle: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(InkType.title)
            .foregroundStyle(OnTimeSpectrum.primaryText)
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

/// The 1 px rule between two rows of a card, the full width of the card.
struct InkHairline: View {
    var body: some View {
        Rectangle()
            .fill(OnTimeSpectrum.rule)
            .frame(height: 1)
    }
}

/// A card holding a vertical stack of rows, with a rule between each pair. `_VariadicView` is what makes "between each pair" possible: a plain
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

/// Title, value, and a round minus and plus filled with the raised surface.
/// These two, the Stop button and the page dots are the only round controls
/// the app draws itself.
/// Not a system `Stepper`: that draws a grey segmented plate that belongs to
/// a `Form`.
struct InkStepperRow: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var unit: String = ""
    /// Replaces the plain number and unit. For a value whose natural reading
    /// changes with its size: 270 minutes is "4 hr 30 min".
    var format: ((Int) -> String)? = nil

    private var display: String {
        if let format { return format(value) }
        return unit.isEmpty ? "\(value)" : "\(value) \(unit)"
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
                .font(.subheadline)
                .foregroundStyle(OnTimeSpectrum.primaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(OnTimeSpectrum.surfaceRaised))
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
            .font(InkType.rowTitle)
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

/// The "+" that adds a row to the section its label sits above. A bare light
/// glyph, as the mockup drew it: it used to sit in an outlined circle. The
/// padding is the tap target, not decoration.
struct PlusButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(OnTimeSpectrum.primaryText)
                .padding(9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A chip: a 10 pt rounded rectangle, never a capsule, never outlined.
///
/// `filled` carries a value you can tap (a shortcut, a saved place).
/// `quiet` is the Add affordance beside a row of them. `unselected` and
/// `selected` are the two states of a `ChipPicker` option: dim on the
/// surface, and black on white.
struct Chip: View {
    enum Style { case filled, quiet, unselected, selected }

    var text: String
    var systemImage: String? = nil
    var style: Style = .filled

    @Environment(\.inkOnCard) private var onCard

    private var foreground: Color {
        switch style {
        case .filled: return OnTimeSpectrum.primaryText
        case .quiet: return OnTimeSpectrum.secondaryText
        case .unselected: return OnTimeSpectrum.tertiaryText
        case .selected: return OnTimeSpectrum.ink
        }
    }

    private var fill: Color {
        if style == .selected { return OnTimeSpectrum.primaryText }
        return onCard ? OnTimeSpectrum.surfaceRaised : OnTimeSpectrum.surface
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(InkType.chip)
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(fill, in: RoundedRectangle(cornerRadius: InkMetric.radius, style: .continuous))
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

/// The app's picker: a row of chips, the selected one filled white and the
/// rest dim. Replaces
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
                             style: option.value == selection ? .selected : .unselected)
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
                        .background(on ? OnTimeSpectrum.primaryText : OnTimeSpectrum.surface,
                                    in: RoundedRectangle(cornerRadius: InkMetric.radius, style: .continuous))
                        .foregroundStyle(on ? OnTimeSpectrum.ink : OnTimeSpectrum.tertiaryText)
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

/// One step of a sequence. The composer, the routine editor and the run
/// screen all draw the same row: a symbol in a fixed column, the name, a meta
/// line, and whatever the screen wants on the right.
///
/// A sequence is one card: the screens put their step rows inside an
/// `InkCard`, which rules them apart, and the row then draws no plate of its
/// own. Outside a card (the Active tab, one row per run) it is its own card.
/// It used to be an outlined card per step with a rail down its leading edge.
///
/// The step you are on marks itself with the raised surface. That was a
/// brighter outline, and nothing has an outline now. Colour on the row is a
/// signal and nothing else: the symbol turns `done` green once a step is
/// finished, and a problem is `late`.
struct StepRowCard<Trailing: View>: View {
    var symbol: String
    var name: String
    var meta: [String] = []
    var state: StepRowState = .upcoming
    /// A problem with this step, shown under the meta line in `late`.
    var problem: String? = nil
    var onDelete: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.inkOnCard) private var onCard

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

    private var row: some View {
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
                        .font(InkType.labelSmall)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        if onCard {
            row
                .background(state == .current ? OnTimeSpectrum.surfaceRaised : Color.clear)
                .contentShape(Rectangle())
        } else {
            row.spectrumCard(fill: state == .current ? OnTimeSpectrum.surfaceRaised
                                                     : OnTimeSpectrum.surface)
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

/// The trailing slot most step rows want: a number in `value` style, regular
/// weight like the rest of the row.
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
                    .font(InkType.labelSmall)
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

    /// A pushed screen's or a sheet's navigation bar: black, hairline, and an
    /// `InkTitle` where the system would put its own semibold title.
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
