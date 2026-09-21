import SwiftUI
import SwiftData

/// The step editor behind "+" on the Now screen. This is where the merge
/// happens: NowView used to add a bare-minutes `QuickStep`; it now creates
/// or edits a real `Block`, with everything the fuller Plan/Block engine
/// already had — a title with autocomplete against `TaskTemplate` history
/// (picking one *is* the observation-history hookup: `RunView.advanceStep`
/// already logs a `DurationSample` against `block.template`, so linking a
/// template here is the entire mechanism), a drive destination via
/// `PlaceSearchField`'s live search, and a per-block open-ended toggle.
struct QuickBlockEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskTemplate.name) private var templates: [TaskTemplate]
    @Query(filter: #Predicate<Place> { $0.isCurrentLocation }) private var currentLocationPlaces: [Place]
    @Query(filter: #Predicate<Place> { !$0.isCurrentLocation }, sort: \Place.name) private var savedPlaces: [Place]

    /// The scratch sequence, for working out where this step sits when it
    /// is not a routine's. Same predicate `SequenceComposer` builds from.
    @Query(filter: #Predicate<Block> { $0.plan == nil && $0.routine == nil }, sort: \Block.order)
    private var scratchBlocks: [Block]

    /// nil means creating a new block, placed by `position` on save.
    let existingBlock: Block?
    /// When set, a new block is owned by this routine's template sequence
    /// instead of being a scratch block. This is what lets the Now screen
    /// and the routine editor share one step editor rather than growing a
    /// second one that drifts.
    var owningRoutine: ScheduledRoutine? = nil
    /// Whether the sequence still has room for a flex or walk step. The
    /// solver can only solve for one open duration per plan; offering the
    /// second one here just produced a silently unsolvable plan later.
    var allowsOpenDuration: Bool = true
    let onSave: () -> Void

    @State private var name = ""
    @State private var kind: BlockKind = .fixed
    @State private var minutes = 10
    @State private var automaticEstimate: Int?
    @State private var hasPopulated = false
    @State private var isOpenEnded = true
    @State private var selectedTemplate: TaskTemplate?
    @State private var originPlace: Place?
    @State private var destinationPlace: Place?
    @State private var showingOriginPicker = false
    @State private var targetTime = Date()
    /// "Use estimate only": skips live MapKit routing for this step and
    /// always uses the manual duration below.
    @State private var useManualEstimateOnly = false
    /// Governs what a *template's* remembered origin becomes when it's
    /// "Current Location" — true (default) keeps it live, re-resolved
    /// against the GPS every time this template autofills a future step;
    /// false snapshots today's coordinate into a fixed `Place` instead, so
    /// future autofills always start from this specific spot regardless of
    /// where the phone actually is then. Only affects `TaskTemplate`
    /// storage in `save()` — this block's own `originPlace` always stays
    /// live if that's what was picked.
    @State private var followsMyLocationForTemplate = true
    /// Where this step sits in its sequence, counted from 1 in the order the
    /// steps happen. The editor owns placement because it is the one screen a
    /// tap on a step always opens: the callers used to pass in a fixed order
    /// and a fixed "is first" flag, a new step could only ever land at the
    /// end, and the only way to move one was to delete it and add it again.
    @State private var position = 1

    /// The rest of the sequence, in order, without this step.
    private var siblings: [Block] {
        let all = (existingBlock?.routine ?? owningRoutine)?.orderedBlocks ?? scratchBlocks
        return all.filter { $0.uuid != existingBlock?.uuid }
    }

    /// A Wait until step only means something as step 1 (see `move` in
    /// `ScheduledRoutineEditor`), so when the sequence has one, nothing else
    /// may be placed in front of it.
    private var positionRange: ClosedRange<Int> {
        (siblings.first?.kind == .startAt ? 2 : 1)...(siblings.count + 1)
    }

    /// The only position `.startAt` is offered from, since "count down to a
    /// clock time" only means something for the step that runs first.
    private var isFirstPosition: Bool {
        position == 1 && !siblings.contains { $0.kind == .startAt }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var originIsCurrentLocation: Bool { originPlace?.isCurrentLocation ?? true }

    private var matchingTemplates: [TaskTemplate] {
        guard kind != .startAt, !trimmedName.isEmpty else { return [] }
        return templates.filter {
            $0.kind != .startAt
                && (!$0.kind.isOpenDuration || allowsOpenDuration)
                && $0.name.localizedCaseInsensitiveContains(trimmedName)
                && $0.id != selectedTemplate?.id
        }
    }

    private var validationMessage: String? {
        if kind.isOpenDuration && !allowsOpenDuration {
            return "This sequence already has a free time or walk step."
        }
        if kind == .drive && !useManualEstimateOnly && destinationPlace == nil {
            return "Choose a destination for the drive."
        }
        if kind == .walk && destinationPlace == nil {
            return "Choose where the walk returns to."
        }
        return nil
    }

    private var kindDescription: String {
        switch kind {
        case .fixed: return "A task with an estimated duration."
        case .drive: return "Travel time from your route, or a manual estimate."
        case .flex: return "Uses the time left before the next step."
        case .walk: return "A walk with a return time and turnaround alert."
        case .startAt: return "Counts down to a clock time before the next step."
        }
    }

    /// The one sheet this view presents: the clock time a `.startAt` step
    /// counts down to.
    @State private var pickingTargetTime = false

    /// The kinds this position and this sequence still allow.
    private var kindOptions: [ChipOption<BlockKind>] {
        var options = [ChipOption(BlockKind.fixed, "Task"), ChipOption(BlockKind.drive, "Drive")]
        if allowsOpenDuration {
            options.append(ChipOption(BlockKind.flex, "Free time"))
            options.append(ChipOption(BlockKind.walk, "Walk"))
        }
        // Still listed for a step that already is one, or its chip would
        // vanish from under the selection.
        if isFirstPosition || kind == .startAt {
            options.append(ChipOption(BlockKind.startAt, "Wait until"))
        }
        return options
    }

    private var showsDuration: Bool { !kind.isOpenDuration && kind != .startAt }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: InkMetric.section) {
                    titleSection
                    kindSection
                    if kind == .walk { walkSection }
                    if kind == .startAt { startAtSection }
                    if kind == .drive { routeSection }
                    durationSection
                    if showsPosition { positionSection }
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
                .padding(.bottom, InkMetric.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .inkNavigation(title: existingBlock == nil ? "NEW STEP" : "EDIT STEP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .inkToolbarButton()
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
            .sheet(isPresented: $pickingTargetTime) {
                FullScreenTimePicker(title: "Wait Until", date: $targetTime)
            }
            .onAppear { populate() }
            .onChange(of: kind) { _, newKind in
                if let selectedTemplate, selectedTemplate.kind != newKind {
                    self.selectedTemplate = nil
                    automaticEstimate = nil
                }
            }
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("NAME")

            InkCard {
                InkTextRow(placeholder: "Step name", text: $name, autocapitalization: .sentences)
                    .onChange(of: name) { _, newName in
                        guard let selectedTemplate,
                              selectedTemplate.name.localizedCaseInsensitiveCompare(
                                newName.trimmingCharacters(in: .whitespacesAndNewlines)
                              ) != .orderedSame else { return }
                        self.selectedTemplate = nil
                        automaticEstimate = nil
                    }

                // A step you have done before, offered by name. Tapping one
                // links this step to its history.
                ForEach(matchingTemplates.prefix(5)) { template in
                    Button {
                        apply(template)
                    } label: {
                        InkRow {
                            Image(systemName: template.symbol)
                                .foregroundStyle(OnTimeSpectrum.secondaryText)
                                .frame(width: 24)
                            Text(template.name)
                                .font(InkType.rowTitle)
                                .foregroundStyle(OnTimeSpectrum.primaryText)
                            Text(template.samples.isEmpty ? "Saved" : "\(template.samples.count) completed")
                                .font(InkType.rowMeta)
                                .foregroundStyle(OnTimeSpectrum.tertiaryText)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if matchingTemplates.isEmpty, let selectedTemplate {
                    InkTextLine(text: selectedTemplate.samples.isEmpty
                                ? "Saved step"
                                : "\(selectedTemplate.samples.count) completed", color: OnTimeSpectrum.secondaryText)
                }
            }
        }
    }

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("TYPE")
            ChipPicker(options: kindOptions, selection: $kind)
            Text(kindDescription)
                .font(InkType.bodyText)
                .foregroundStyle(OnTimeSpectrum.secondaryText)
        }
    }

    private var walkSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("RETURN TO")
            InkCard {
                PlaceSearchField(label: "Back to", place: $destinationPlace)
            }
        }
    }

    private var startAtSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("WAIT UNTIL")
            InkCard {
                InkValueRow(title: "Time",
                            value: TimeFormatting.clockString(targetTime),
                            chevron: true) { pickingTargetTime = true }
            }
        }
    }

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("ROUTE")
            InkCard {
                InkToggleRow(title: "Use manual duration", isOn: $useManualEstimateOnly)

                if !useManualEstimateOnly {
                    if showingOriginPicker {
                        PlaceSearchField(label: "From", place: $originPlace)
                    } else {
                        // A menu, not a button that opens the search field.
                        // Origin defaults to Current Location, so the old
                        // version made the overwhelmingly common case the most
                        // tedious one: tapping a row that already read
                        // "Current Location" cleared it and dropped you into a
                        // text box whose only useful affordance was a chip
                        // saying "Current Location". Picking a place is now one
                        // tap; searching for a new one is still available below.
                        Menu {
                            Button {
                                originPlace = currentLocationPlace()
                            } label: {
                                Label("Current Location", systemImage: "location.fill")
                            }
                            ForEach(savedPlaces) { saved in
                                Button(saved.name) { originPlace = saved }
                            }
                            Divider()
                            Button {
                                originPlace = nil
                                showingOriginPicker = true
                            } label: {
                                Label("Search a place", systemImage: "magnifyingglass")
                            }
                        } label: {
                            InkRow {
                                Text("From")
                                    .font(InkType.rowTitle)
                                    .foregroundStyle(OnTimeSpectrum.primaryText)
                                Spacer(minLength: 8)
                                Text(originPlace?.name ?? "Current Location")
                                    .font(InkType.bodyText)
                                    .foregroundStyle(OnTimeSpectrum.secondaryText)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(OnTimeSpectrum.tertiaryText)
                            }
                        }
                    }

                    PlaceSearchField(label: "To", place: $destinationPlace)

                    // Only matters once there's a template to save it on: an
                    // untitled step never gets one, so the toggle would have
                    // nothing to affect.
                    if !trimmedName.isEmpty, originIsCurrentLocation {
                        InkToggleRow(title: "Remember current location", isOn: $followsMyLocationForTemplate)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var durationSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel(showsDuration ? "DURATION" : "WHEN TIME IS UP")
            if kind.isOpenDuration {
                Text("This step ends when you mark it complete.")
                    .font(InkType.bodyText)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            } else {
                InkCard {
                    if showsDuration {
                        InkRow { DurationScrubber(minutes: $minutes) }
                    }
                    InkToggleRow(title: "Next step starts by itself", isOn: $isOpenEnded)
                }
                Text(advanceCaption)
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            }
            if kind == .drive && !useManualEstimateOnly {
                Text("Live travel time replaces this estimate when available.")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.secondaryText)
            }
        }
    }

    /// What the toggle above it does, given the switch that outranks it.
    ///
    /// A step only moves on by itself when this toggle *and* Settings' "Auto
    /// advance steps" are both on (`RunEngine.autoAdvanceEligible`). The old
    /// caption, "Advances when automatic advance is on for the countdown",
    /// named neither the switch nor where it lives, so with Settings off this
    /// toggle read as on and did nothing.
    private var advanceCaption: String {
        guard isOpenEnded else {
            return "This step waits for Next Step, even with Auto advance steps on in Settings."
        }
        return AppSettings.shared.autoAdvanceEnabled
            ? "When this step's time is up, the next one starts."
            : "Auto advance steps is off in Settings, so this step waits for Next Step."
    }

    /// Hidden for a Wait until step, which is pinned first, and when there is
    /// nowhere else to go.
    private var showsPosition: Bool {
        kind != .startAt && positionRange.count > 1
    }

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("POSITION")
            InkCard {
                InkStepperRow(title: "Step", value: $position, range: positionRange,
                              unit: "of \(siblings.count + 1)")
            }
        }
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(InkType.rowMeta)
                    .foregroundStyle(OnTimeSpectrum.waiting)
            }
            Button(existingBlock == nil ? "Add step" : "Save changes", action: save)
                .font(InkType.buttonProminent)
                .buttonStyle(SpectrumButtonStyle())
                .disabled(validationMessage != nil)
                .opacity(validationMessage == nil ? 1 : 0.38)
        }
        .padding(.horizontal, InkMetric.page)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(OnTimeSpectrum.ink)
    }

    private func apply(_ template: TaskTemplate) {
        guard !template.kind.isOpenDuration || allowsOpenDuration else { return }
        name = template.name
        kind = template.kind
        selectedTemplate = template
        let obs = template.samples.map { DurationObservation(minutes: $0.minutes, recordedAt: $0.recordedAt) }
        let confidence: Confidence = AppSettings.shared.confidenceIsSafe ? .safe : .typical
        minutes = Estimator.estimate(observations: obs, prior: template.manualEstimateMinutes, confidence: confidence)
        automaticEstimate = minutes
        if template.kind == .walk {
            destinationPlace = template.destinationPlace
        }
        if template.kind == .drive {
            originPlace = template.originPlace
            destinationPlace = template.destinationPlace
            useManualEstimateOnly = template.useManualEstimateOnly
            // The template's own origin is already whatever it was saved
            // as (live sentinel or a fixed snapshot) — this toggle only
            // matters again if it gets re-saved, so start it at the
            // default rather than trying to infer which one produced it.
            followsMyLocationForTemplate = true
        }
    }

    private func populate() {
        guard !hasPopulated else { return }
        hasPopulated = true
        position = siblings.count + 1
        if let block = existingBlock {
            let all = block.routine?.orderedBlocks ?? scratchBlocks
            position = (all.firstIndex { $0.uuid == block.uuid } ?? siblings.count) + 1
            name = block.name
            kind = block.kind
            minutes = TravelTimeService.shared.manualEstimateMinutes(for: block)
            if block.estimateOverrideMinutes == nil, block.template != nil {
                automaticEstimate = minutes
            }
            isOpenEnded = block.isOpenEnded
            selectedTemplate = block.template
            originPlace = block.originPlace
            destinationPlace = block.destinationPlace
            useManualEstimateOnly = block.useManualEstimateOnly
            if let hour = block.targetHour, let minute = block.targetMinute {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = hour
                comps.minute = minute
                targetTime = Calendar.current.date(from: comps) ?? Date()
            }
        }
        if originPlace == nil, kind == .drive || existingBlock == nil {
            originPlace = currentLocationPlaces.first
        }
    }

    private func save() {
        guard validationMessage == nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = resolveTemplate(named: trimmed)
        let estimateOverride = (kind.isOpenDuration || kind == .startAt
                                || (template != nil && automaticEstimate == minutes)) ? nil : minutes
        let displayName = trimmed.isEmpty ? genericName() : trimmed
        let resolvedOrigin = kind == .drive ? (originPlace ?? currentLocationPlace()) : nil
        let targetComps = kind == .startAt ? Calendar.current.dateComponents([.hour, .minute], from: targetTime) : nil
        // Read before a new block is inserted: once it belongs to the routine
        // it shows up in `siblings` itself, and would be placed twice.
        var sequence = siblings
        let place = kind == .startAt
            ? 1
            : min(max(position, positionRange.lowerBound), positionRange.upperBound)

        let saved: Block
        if let block = existingBlock {
            saved = block
            block.name = displayName
            block.kind = kind
            block.template = template
            block.estimateOverrideMinutes = estimateOverride
            block.resolvedMinutes = 0
            block.resolvedAt = nil
            block.originPlace = resolvedOrigin
            block.destinationPlace = (kind == .drive || kind == .walk) ? destinationPlace : nil
            block.targetHour = targetComps?.hour
            block.targetMinute = targetComps?.minute
            block.isOpenEnded = isOpenEnded
            block.useManualEstimateOnly = kind == .drive ? useManualEstimateOnly : false
        } else {
            let block = Block(
                order: sequence.count,
                name: displayName,
                kind: kind,
                template: template,
                estimateOverrideMinutes: estimateOverride,
                originPlace: resolvedOrigin,
                destinationPlace: (kind == .drive || kind == .walk) ? destinationPlace : nil,
                targetHour: targetComps?.hour,
                targetMinute: targetComps?.minute,
                isOpenEnded: isOpenEnded,
                useManualEstimateOnly: kind == .drive ? useManualEstimateOnly : false
            )
            modelContext.insert(block)
            // nil leaves it a scratch block (`plan == nil && routine == nil`),
            // which is what the Now screen queries for.
            block.routine = owningRoutine
            saved = block
        }

        // Every step gets a fresh, contiguous `0...n-1`, this one in its
        // chosen place. A gap or a duplicate `order` is a tied sort key, which
        // is what made a new step flash into place and then swap somewhere
        // else on the next redraw as SwiftData resolved the tie differently
        // between fetches.
        sequence.insert(saved, at: min(place - 1, sequence.count))
        for (index, block) in sequence.enumerated() {
            block.order = index
        }

        // Stamp the route back onto the template so the next time this
        // title autocompletes, "From"/"To" fill in too — not just
        // name/kind/duration. `resolvedOrigin` snapshots into a fixed
        // `Place` here when the user turned off "Follow My Location";
        // `block.originPlace` above is untouched by that and stays live.
        if kind == .drive, let template, let resolvedOrigin {
            template.useManualEstimateOnly = useManualEstimateOnly
            template.destinationPlace = destinationPlace
            if resolvedOrigin.isCurrentLocation && !followsMyLocationForTemplate {
                template.originPlace = snapshotCurrentLocation()
            } else {
                template.originPlace = resolvedOrigin
            }
        }
        if kind == .walk, let template {
            template.destinationPlace = destinationPlace
        }

        onSave()
        dismiss()
    }

    /// Templates populate themselves from use rather than needing a trip to
    /// the Templates tab: a typed name that doesn't match an existing
    /// template (case-insensitively) becomes one automatically, seeded from
    /// this step's duration.
    /// No template for `.startAt` — it isn't a reusable duration-with-history
    /// the way "Shower" or "Drive to masjid" are, it's a one-off clock time.
    private func resolveTemplate(named trimmed: String) -> TaskTemplate? {
        guard kind != .startAt, !trimmed.isEmpty else { return nil }
        if let selectedTemplate, selectedTemplate.kind == kind,
           selectedTemplate.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame {
            return selectedTemplate
        }
        if let existing = templates.first(where: {
            $0.kind == kind && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing
        }
        let newTemplate = TaskTemplate(name: trimmed, symbol: kind.defaultSymbol, kind: kind, manualEstimateMinutes: minutes)
        modelContext.insert(newTemplate)
        return newTemplate
    }

    private func genericName() -> String {
        switch kind {
        case .fixed: return "Step"
        case .drive: return "Drive"
        case .flex: return "Free time"
        case .walk: return "Walk"
        case .startAt: return "Wait"
        }
    }

    private func currentLocationPlace() -> Place {
        Place.currentLocationSentinel(in: modelContext)
    }

    /// Pins a template's origin to right here, right now, instead of the
    /// live "Current Location" sentinel — for a template like "Drive to
    /// Grandma's" that happens to start from wherever the user is today,
    /// but should always start from *this* spot on future autofills, not
    /// wherever the phone happens to be then. Falls back to the sentinel
    /// itself when there's no real fix yet — same guard `resolve(block:)`
    /// uses before routing, since a (0, 0) snapshot would silently pin
    /// every future use of this template to the Gulf of Guinea.
    private func snapshotCurrentLocation() -> Place {
        let settings = AppSettings.shared
        guard settings.hasRealLocation else { return currentLocationPlace() }
        // Reuse before inserting: every re-save with the toggle off used to
        // mint a brand new identical "Saved Location" row, orphaning the
        // previous snapshot and filling the origin picker with
        // indistinguishable entries.
        if let existing = savedPlaces.first(where: {
            abs($0.latitude - settings.lastLatitude) < 0.0001
                && abs($0.longitude - settings.lastLongitude) < 0.0001
        }) {
            return existing
        }
        if let prior = selectedTemplate?.originPlace, !prior.isCurrentLocation, prior.name == "Saved Location" {
            prior.latitude = settings.lastLatitude
            prior.longitude = settings.lastLongitude
            return prior
        }
        let place = Place(name: "Saved Location", latitude: settings.lastLatitude, longitude: settings.lastLongitude)
        modelContext.insert(place)
        return place
    }
}
