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

    /// nil means creating a new scratch block at the given order.
    let existingBlock: Block?
    let newBlockOrder: Int
    /// Whether this block is (or, for a new block, will become) the first
    /// step in the sequence — the only position `.startAt` is offered from,
    /// since "count down to a clock time" only means something for the step
    /// that's actually running right now.
    let isFirstPosition: Bool
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
    /// Guards the template-selection round trip: `apply(template)` writes
    /// the template's name into the field, and without this the `onChange`
    /// below immediately cleared the very selection it had just made — the
    /// exact shape of the historical `PlaceSearchField` bug.
    @State private var isApplyingTemplate = false
    @State private var minutes = 10
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

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var originIsCurrentLocation: Bool { originPlace?.isCurrentLocation ?? true }

    private var matchingTemplates: [TaskTemplate] {
        guard kind != .startAt, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return templates.filter {
            $0.name.localizedCaseInsensitiveContains(name) && $0.name.localizedCaseInsensitiveCompare(name) != .orderedSame
        }
    }

    /// The one sheet this view presents: the clock time a `.startAt` step
    /// counts down to.
    @State private var pickingTargetTime = false

    /// The kinds this position and this sequence still allow.
    private var kindOptions: [ChipOption<BlockKind>] {
        var options = [ChipOption(BlockKind.fixed, "Fixed"), ChipOption(BlockKind.drive, "Drive")]
        if allowsOpenDuration || kind.isOpenDuration {
            options.append(ChipOption(BlockKind.flex, "Flex"))
            options.append(ChipOption(BlockKind.walk, "Walk"))
        }
        if isFirstPosition {
            options.append(ChipOption(BlockKind.startAt, "Starts at"))
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
                }
                .padding(.horizontal, InkMetric.page)
                .padding(.top, InkMetric.labelToCard)
                .padding(.bottom, InkMetric.section)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .inkNavigation(title: existingBlock == nil ? "NEW STEP" : "EDIT STEP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .inkToolbarButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .inkToolbarButton()
                        .disabled((kind == .drive && !useManualEstimateOnly && destinationPlace == nil)
                                  || (kind == .walk && destinationPlace == nil))
                }
            }
            .sheet(isPresented: $pickingTargetTime) {
                FullScreenTimePicker(title: "Starts At", date: $targetTime)
            }
            .onAppear { populate() }
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("TITLE")

            InkCard {
                InkTextRow(placeholder: "Title", text: $name, autocapitalization: .sentences)
                    .onChange(of: name) { _, _ in
                        if isApplyingTemplate {
                            isApplyingTemplate = false
                            return
                        }
                        selectedTemplate = nil
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
                            Text("\(template.samples.count) before")
                                .font(InkType.rowMeta)
                                .foregroundStyle(OnTimeSpectrum.tertiaryText)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if matchingTemplates.isEmpty, let selectedTemplate {
                    InkTextLine(text: "Linked to \(selectedTemplate.name)")
                }
            }
        }
    }

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("KIND")
            ChipPicker(options: kindOptions, selection: $kind)
        }
    }

    private var walkSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("WALK")
            InkCard {
                PlaceSearchField(label: "Back to", place: $destinationPlace)
            }
        }
    }

    private var startAtSection: some View {
        VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
            SectionLabel("STARTS AT")
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
                InkToggleRow(title: "Use estimate only", isOn: $useManualEstimateOnly)

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
                        InkToggleRow(title: "Follow my location", isOn: $followsMyLocationForTemplate)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var durationSection: some View {
        if showsDuration {
            VStack(alignment: .leading, spacing: InkMetric.labelToCard) {
                SectionLabel(kind == .drive ? "DRIVE ESTIMATE" : "DURATION")
                VStack(spacing: InkMetric.cardToCard) {
                    InkCard {
                        InkRow {
                            DurationScrubber(minutes: $minutes)
                        }
                    }
                    InkCard {
                        InkToggleRow(title: "Move on automatically", isOn: $isOpenEnded)
                    }
                }
            }
        } else {
            InkCard {
                InkToggleRow(title: "Move on automatically", isOn: $isOpenEnded)
            }
        }
    }

    private func apply(_ template: TaskTemplate) {
        // Guard only when the assignment will actually change the text — a
        // no-op assignment never fires `onChange`, and a flag left standing
        // would swallow the user's next keystroke instead. (Today the
        // autocomplete list excludes exact matches, so the names always
        // differ; the check is what keeps that assumption from becoming a
        // trap.)
        if name != template.name { isApplyingTemplate = true }
        name = template.name
        kind = template.kind
        selectedTemplate = template
        let obs = template.samples.map { DurationObservation(minutes: $0.minutes, recordedAt: $0.recordedAt) }
        let confidence: Confidence = AppSettings.shared.confidenceIsSafe ? .safe : .typical
        minutes = Estimator.estimate(observations: obs, prior: template.manualEstimateMinutes, confidence: confidence)
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
        if let block = existingBlock {
            name = block.name
            kind = block.kind
            minutes = block.estimateOverrideMinutes ?? (block.resolvedMinutes > 0 ? block.resolvedMinutes : 10)
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = resolveTemplate(named: trimmed)
        let displayName = trimmed.isEmpty ? genericName() : trimmed
        let resolvedOrigin = kind == .drive ? (originPlace ?? currentLocationPlace()) : nil
        let targetComps = kind == .startAt ? Calendar.current.dateComponents([.hour, .minute], from: targetTime) : nil

        if let block = existingBlock {
            block.name = displayName
            block.kind = kind
            block.template = template
            block.estimateOverrideMinutes = (kind.isOpenDuration || kind == .startAt) ? nil : minutes
            block.originPlace = resolvedOrigin
            block.destinationPlace = (kind == .drive || kind == .walk) ? destinationPlace : nil
            block.targetHour = targetComps?.hour
            block.targetMinute = targetComps?.minute
            block.isOpenEnded = isOpenEnded
            block.useManualEstimateOnly = kind == .drive ? useManualEstimateOnly : false
        } else {
            let block = Block(
                order: newBlockOrder,
                name: displayName,
                kind: kind,
                template: template,
                estimateOverrideMinutes: (kind.isOpenDuration || kind == .startAt) ? nil : minutes,
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
        if let selectedTemplate, selectedTemplate.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame {
            return selectedTemplate
        }
        if let existing = templates.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
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
        case .flex: return "Go"
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
