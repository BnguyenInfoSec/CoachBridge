import SwiftUI

/// The setup questions — what you're training for, when you can train, what you like — and the
/// same screen serves as the editor afterwards. Everything the plan used to hardcode lives here.
struct ProfileSetupView: View {
    @EnvironmentObject private var plan: PlanModel
    @EnvironmentObject private var dashboard: DashboardModel
    @Environment(\.dismiss) private var dismiss

    /// First run shows a Done button that saves and closes; Settings shows a plain editor.
    var isSetup = false

    @State private var draft = AthleteProfile()
    @State private var loaded = false
    @State private var newCommitment = false
    @State private var newBlackout = false
    @State private var newEvent = false

    private let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// One training block as a row the list can identify.
    private struct BlockRow: Identifiable { let id: String; let asked: Int; let fitted: Int }

    var body: some View {
        Form {
            goalSection
            capacitySection
            blocksSection
            daysSection
            equipmentSection
            if draft.hasBike { bikeSection }
            if draft.sports.contains(.run) { shoesSection }
            lifeSection
            preferencesSection
            notesSection
            previewSection
        }
        .screenBackground(Palette.Tab.plan)
        .navigationTitle(isSetup ? "Set up your plan" : "Your training")
        .keyboardDismissible()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSetup {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                        .disabled(draft.eventKind == .general && draft.eventDateISO.isEmpty)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            draft = plan.profile
            if draft.availableDays.isEmpty { draft.availableDays = [0, 1, 2, 3, 4, 5, 6] }
            loaded = true
        }
        .onDisappear { save() }
        .sheet(isPresented: $newCommitment) { CommitmentEditor { draft.commitments.append($0) } }
        .sheet(isPresented: $newBlackout) { BlackoutEditor { draft.blackouts.append($0) } }
        .sheet(isPresented: $newEvent) { EventEditor { draft.events.append($0) } }
    }

    private func save() {
        guard loaded else { return }
        plan.profile = draft
    }

    // MARK: Sections

    private var goalSection: some View {
        Section {
            Picker("I'm training for", selection: $draft.eventKind) {
                ForEach(EventKind.allCases) { k in
                    Label(k.label, systemImage: k.symbol).tag(k)
                }
            }
            TextField("Event name (optional)", text: $draft.eventName)
            Toggle("I have a date", isOn: Binding(
                get: { !draft.eventDateISO.isEmpty },
                set: { on in
                    draft.eventDateISO = on
                        ? AthleteProfile.iso(Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now)
                        : ""
                }))
            if !draft.eventDateISO.isEmpty {
                DatePicker("Event date", selection: Binding(
                    get: { AthleteProfile.date(draft.eventDateISO) },
                    set: { draft.eventDateISO = AthleteProfile.iso($0) }), displayedComponents: .date)
            }
            DatePicker("Plan starts", selection: Binding(
                get: { AthleteProfile.date(draft.startDate) },
                set: { draft.startDateISO = AthleteProfile.iso($0) }), displayedComponents: .date)
            VStack(alignment: .leading, spacing: 4) {
                Text("What would make this a good day?")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Finish strong, under 6 hours, still smiling", text: $draft.goal, axis: .vertical)
                    .lineLimit(2...5)
            }
        } header: {
            Text("The goal")
        } footer: {
            Text(draft.eventDateISO.isEmpty
                 ? "Without a date the plan runs \(draft.eventKind.typicalWeeks) weeks from today. You can add one later and everything reshapes around it."
                 : "The whole plan is built backwards from this date — phases, volume and taper.")
        }
    }

    private var capacitySection: some View {
        Section {
            LabeledContent("Training now") {
                Text("\(draft.currentWeeklyHours, specifier: "%.1f") h/wk").monospacedDigit()
            }
            Slider(value: $draft.currentWeeklyHours, in: 0...20, step: 0.5)
            LabeledContent("Most I can give") {
                Text("\(draft.peakHours, specifier: "%.1f") h/wk").monospacedDigit()
            }
            Slider(value: Binding(
                get: { draft.maxWeeklyHours ?? draft.eventKind.peakWeeklyHours },
                set: { draft.maxWeeklyHours = $0 }), in: 2...25, step: 0.5)
        } header: {
            Text("Hours")
        } footer: {
            Text("Be honest about \"training now\" — the plan ramps from there, and starting above your current load is how people get hurt. The peak is what the build block aims at.")
        }
    }

    /// Weeks per training block. Suggested lengths are shown until the athlete touches one;
    /// after that their numbers win and the plan is fitted around them.
    private var blocksSection: some View {
        let total = PlanBlueprint.totalWeeks(draft)
        let rows = blockRows(total: total)
        let requested = rows.reduce(0) { $0 + $1.asked }
        let custom = draft.blockWeeks != nil

        return Section {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Stepper(value: blockBinding(row.id, fallback: row.asked), in: 0...total) {
                        HStack {
                            Text(PlanBlueprint.blockName(row.id))
                            Spacer()
                            Text(weekLabel(row.asked))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(row.asked == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        }
                    }
                    // When the runway can't take what was asked for, say what the block will
                    // actually be rather than silently planning something else.
                    if row.fitted != row.asked {
                        Text("becomes \(weekLabel(row.fitted)) to fit the runway")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Text(PlanBlueprint.blockBlurb(row.id))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if custom {
                Button("Use the suggested lengths") { draft.blockWeeks = nil }
            }
        } header: {
            Text("Training blocks")
        } footer: {
            Text(blocksFooter(total: total, requested: requested, custom: custom))
        }
    }

    /// What each block was asked for, alongside what it becomes once the runway is enforced.
    /// They differ only when the athlete's numbers don't add up to the weeks available.
    private func blockRows(total: Int) -> [BlockRow] {
        let suggested = PlanBlueprint.suggestedBlocks(draft, totalWeeks: total)
        let fitted = Dictionary(uniqueKeysWithValues: PlanBlueprint.blockLengths(draft, totalWeeks: total))
        return PlanBlueprint.blockOrder.map { id in
            BlockRow(id: id,
                     asked: draft.blockWeeks?[id] ?? suggested[id] ?? 0,
                     fitted: fitted[id] ?? 0)
        }
    }

    private func weekLabel(_ n: Int) -> String {
        switch n {
        case 0: return "skipped"
        case 1: return "1 week"
        default: return "\(n) weeks"
        }
    }

    /// Editing any block switches the whole set to overrides, so the others stop moving under
    /// the athlete's hands the next time a date changes.
    private func blockBinding(_ id: String, fallback: Int) -> Binding<Int> {
        Binding(
            get: { draft.blockWeeks?[id] ?? fallback },
            set: { new in
                var all = draft.blockWeeks ?? Dictionary(
                    uniqueKeysWithValues: PlanBlueprint.blockLengths(draft, totalWeeks: PlanBlueprint.totalWeeks(draft)))
                all[id] = max(0, new)
                draft.blockWeeks = all
            })
    }

    private func blocksFooter(total: Int, requested: Int, custom: Bool) -> String {
        let runway = draft.eventDateISO.isEmpty
            ? "\(total) weeks from today"
            : "\(total) weeks until \(draft.eventName.isEmpty ? "the event" : draft.eventName)"
        if !custom {
            return "You have \(runway), split the way most plans for this distance are. Change any block and the rest are fitted around it."
        }
        if requested == total {
            return "Your blocks fill the \(runway) exactly."
        }
        return requested < total
            ? "Your blocks come to \(requested) of \(total) weeks; the spare \(total - requested) go into Base 1."
            : "Your blocks come to \(requested) weeks but there are only \(total). The extra is trimmed from Base 1, then Build, then Base 2 — the taper is never cut."
    }

    private var equipmentSection: some View {
        Section {
            ForEach(Equipment.groups, id: \.self) { group in
                DisclosureGroup(group) {
                    ForEach(Equipment.inGroup(group)) { item in
                        Toggle(item.label, isOn: Binding(
                            get: { draft.has(item) },
                            set: { draft.set(item, $0) }))
                    }
                }
            }
        } header: {
            Text("What you've got")
        } footer: {
            Text(equipmentFooter)
        }
    }

    /// The bike: what it is, the groupset, and tire pressure worked out from your weight, tire,
    /// rim and riding — filled in automatically until you type your own.
    private var bikeSection: some View {
        let healthKg = dashboard.data?.today.metrics[.weight].map { $0 * 0.453_592 }
        let rec = (draft.gear ?? Gear()).recommendedPressure(riderKg: healthKg)
        return Section {
            TextField("Your bike, e.g. Canyon Speedmax CF 8", text: gear(\.bike))
                .textInputAutocapitalization(.words)
            Picker("Groupset", selection: gear(\.groupset)) {
                Text("Not set").tag(Gear.Groupset?.none)
                ForEach(["Shimano", "SRAM", "Campagnolo", "Other"], id: \.self) { brand in
                    ForEach(Gear.Groupset.allCases.filter { $0.brand == brand }) { g in
                        Text(brand == "Other" ? g.label : "\(brand) \(g.label)").tag(Optional(g))
                    }
                }
            }
            TextField("Gearing, e.g. 50/34, 11–34 or 42T, 10–44", text: gear(\.gearing))

            TextField("Tires, e.g. GP5000 S TR", text: gear(\.tires))
            Picker("Tire width", selection: gear(\.tireWidthMM)) {
                Text("Not set").tag(Int?.none)
                ForEach([23, 25, 28, 30, 32, 35, 38, 40, 42, 45, 50, 56, 61], id: \.self) { w in
                    Text(w >= 50 ? String(format: "%d mm (%.1f\")", w, Double(w) / 25.4) : "\(w) mm").tag(Optional(w))
                }
            }
            Picker("Tire setup", selection: gear(\.tireSetup)) {
                Text("Not sure").tag(Gear.TireSetup?.none)
                ForEach(Gear.TireSetup.allCases) { Text($0.label).tag(Optional($0)) }
            }
            Picker("Rims", selection: gear(\.rim)) {
                Text("Not sure").tag(TirePressure.Rim?.none)
                ForEach(TirePressure.Rim.allCases) { Text($0.label).tag(Optional($0)) }
            }
            Picker("Bike type", selection: gear(\.pressureBike)) {
                Text("Not set").tag(TirePressure.Bike?.none)
                ForEach(TirePressure.Bike.allCases) { Text($0.label).tag(Optional($0)) }
            }
            Picker("Riding", selection: gear(\.riding)) {
                Text("Default for the bike").tag(TirePressure.Riding?.none)
                ForEach(TirePressure.Riding.allCases) { Text($0.label).tag(Optional($0)) }
            }
            LabeledContent("Your weight") {
                TextField(healthKg.map { "\(Int(($0 / 0.453_592).rounded())) lb from Health" } ?? "lb",
                          value: Binding(get: { draft.gear?.riderWeightKg.map { ($0 / 0.453_592).rounded() } },
                                         set: { lb in var g = draft.gear ?? Gear(); g.riderWeightKg = lb.map { $0 * 0.453_592 }; draft.gear = g }),
                          format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            pressureRow("Front", \.frontPSI)
            pressureRow("Rear", \.rearPSI)
            if let rec {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Recommended \(Int(rec.frontPSI)) / \(Int(rec.rearPSI)) psi (\(String(format: "%.1f", rec.frontBar)) / \(String(format: "%.1f", rec.rearBar)) bar)")
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                        if draft.gear?.pressuresCustom == true {
                            Button("Use") { applyRecommendation(rec, force: true) }
                        }
                    }
                    ForEach(rec.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text("Add your weight (or allow Health) and a tire width for a recommended pressure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Your bike")
        } footer: {
            Text("Pressure is worked out from your weight, bike, tire width, tubes or tubeless, rims and what you're riding, and fills in until you set your own. Your weight stays on this iPhone; the bike, groupset, tires and pressures go to the coach.")
        }
        .onChange(of: rec) { _, new in if let new { applyRecommendation(new, force: false) } }
        .onAppear { if let rec { applyRecommendation(rec, force: false) } }
    }

    private func pressureRow(_ label: String, _ field: WritableKeyPath<Gear, Double?>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("psi", value: Binding(
                    get: { draft.gear?[keyPath: field] },
                    set: { v in
                        var g = draft.gear ?? Gear()
                        g[keyPath: field] = v
                        g.pressuresCustom = true              // the athlete's own number now wins
                        draft.gear = g
                    }), format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 70)
                Text("psi").foregroundStyle(.secondary)
                if let v = draft.gear?[keyPath: field] {
                    Text(String(format: "%.1f bar", v / TirePressure.psiPerBar)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func applyRecommendation(_ rec: TirePressure.Result, force: Bool) {
        var g = draft.gear ?? Gear()
        guard force || !g.pressuresCustom else { return }
        guard g.frontPSI != rec.frontPSI || g.rearPSI != rec.rearPSI || g.pressuresCustom else { return }
        g.frontPSI = rec.frontPSI
        g.rearPSI = rec.rearPSI
        g.pressuresCustom = false
        draft.gear = g
    }

    private var shoesSection: some View {
        Section {
                ForEach(shoes) { $shoe in
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Shoe type", selection: $shoe.category) {
                            ForEach(Gear.ShoeCategory.allCases) { Text($0.label).tag($0) }
                        }
                        TextField("Model — \(shoe.category.example)", text: $shoe.model)
                            .font(.subheadline)
                    }
                }
                .onDelete { idx in
                    var g = draft.gear ?? Gear()
                    g.shoes.remove(atOffsets: idx)
                    draft.gear = g
                }
                Menu {
                    ForEach(Gear.ShoeCategory.allCases) { c in
                        Button("\(c.label) (\(c.example.replacingOccurrences(of: "e.g. ", with: "")))") {
                            var g = draft.gear ?? Gear()
                            g.shoes.append(Gear.Shoe(category: c))
                            draft.gear = g
                        }
                    }
                } label: {
                    Label("Add running shoes", systemImage: "shoe.fill")
                }
        } header: {
            Text("Running shoes")
        } footer: {
            Text("The coach uses these to say which pair suits each run.")
        }
    }

    /// A field of the athlete's gear, creating the gear record on first edit.
    private func gear<T>(_ field: WritableKeyPath<Gear, T>) -> Binding<T> {
        Binding {
            (draft.gear ?? Gear())[keyPath: field]
        } set: { value in
            var g = draft.gear ?? Gear()
            g[keyPath: field] = value
            draft.gear = g
        }
    }

    private var shoes: Binding<[Gear.Shoe]> { gear(\.shoes) }

    private var equipmentFooter: String {
        equipmentFooterText
    }

    private var equipmentFooterText: String {
        if draft.eventKind.isTriathlon && !draft.hasBike {
            return "No bike ticked, so the plan can't program riding — worth fixing before a triathlon."
        }
        if !draft.hasTrainer {
            return "The plan only programs what you can actually do. Tick an indoor trainer and rides can move inside when the weather or the light is against you."
        }
        return "The plan only programs what you can actually do. A power meter turns ride targets into watts; a pool or open water is what makes swimming possible at all. Your bike, tires and shoes go to the coach, so it can say which pair suits a run or what to check before a wet descent."
    }

    private var daysSection: some View {
        Section {
            ForEach(0..<7, id: \.self) { d in
                Toggle(weekdayNames[d], isOn: Binding(
                    get: { draft.availableDays.contains(d) },
                    set: { on in
                        var days = Set(draft.availableDays)
                        if on { days.insert(d) } else { days.remove(d) }
                        draft.availableDays = days.sorted()
                        if !draft.availableDays.contains(draft.longDay) {
                            draft.longDay = draft.availableDays.last ?? 6
                        }
                    }))
            }
            Picker("Long session day", selection: $draft.longDay) {
                ForEach(draft.availableDays, id: \.self) { Text(weekdayNames[$0]).tag($0) }
            }
        } header: {
            Text("Days you can train")
        } footer: {
            Text("The long ride or run goes on your long day, and the second-longest next to it. Days you turn off stay rest days, permanently.")
        }
    }

    private var lifeSection: some View {
        Section {
            DisclosureGroup("Work or school hours") {
                ForEach(0..<7, id: \.self) { d in
                    Toggle(weekdayNames[d], isOn: Binding(
                        get: { draft.work.weekdays.contains(d) },
                        set: { on in
                            var days = Set(draft.work.weekdays)
                            if on { days.insert(d) } else { days.remove(d) }
                            draft.work.weekdays = days.sorted()
                        }))
                }
                Stepper("Starts \(draft.work.startHour):00", value: $draft.work.startHour, in: 0...23)
                Stepper("Ends \(draft.work.endHour):00", value: $draft.work.endHour, in: 1...23)
            }

            ForEach(draft.commitments) { c in
                Text(c.summary).font(.subheadline)
            }
            .onDelete { draft.commitments.remove(atOffsets: $0) }
            Button("Add a class or standing commitment") { newCommitment = true }

            ForEach(draft.blackouts) { b in
                Text(b.summary).font(.subheadline)
            }
            .onDelete { draft.blackouts.remove(atOffsets: $0) }
            Button("Add a holiday or trip") { newBlackout = true }

            ForEach(draft.events) { e in
                Text("\(e.title) · \(e.dateISO)").font(.subheadline)
            }
            .onDelete { draft.events.remove(atOffsets: $0) }
            Button("Add a race or event") { newEvent = true }
        } header: {
            Text("The rest of your life")
        } footer: {
            Text("Classes and shifts stay rest evenings. Trips become easy weeks or rest weeks. Races along the way show up on the calendar and the coach plans around them.")
        }
    }

    private var preferencesSection: some View {
        Section {
            Stepper("Lift \(draft.liftsPerWeek)× a week", value: $draft.liftsPerWeek, in: 0...4)

            DisclosureGroup("Sports I'd rather avoid") {
                ForEach([SessionKind.swim, .bike, .run, .lift], id: \.self) { k in
                    Toggle(k.label, isOn: Binding(
                        get: { draft.avoidedSports.contains(k) },
                        set: { on in
                            if on {
                                draft.avoidedSports.append(k)
                                draft.preferredSports.removeAll { $0 == k }
                            } else {
                                draft.avoidedSports.removeAll { $0 == k }
                            }
                        }))
                }
            }
        } header: {
            Text("How you like to train")
        } footer: {
            Text(draft.eventKind.isTriathlon && !draft.hasPool && !draft.openWaterAccess
                 ? "Without water access the plan drops swimming entirely — worth fixing before a triathlon."
                 : "The plan only programs sports you can actually do.")
        }
    }

    private var notesSection: some View {
        Section {
            TextField("Anything else the coach should know", text: $draft.notes, axis: .vertical)
                .lineLimit(4...12)
        } header: {
            Text("In your own words")
        } footer: {
            Text("Free text — injuries, past races, how you like to be coached, anything odd about your data. It goes to the coach with every message.")
        }
    }

    private var previewSection: some View {
        Section {
            let bp = PlanBlueprint.make(draft)
            ForEach(bp.phases, id: \.id) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(p.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(p.hours).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("\(p.start) → \(p.end)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Your plan, as it stands")
        } footer: {
            Text("Built from the answers above. Change anything and this rebuilds — nothing is locked in.")
        }
    }
}

// MARK: - Small editors

private struct CommitmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Commitment) -> Void

    @State private var title = "Class"
    @State private var weekdays: Set<Int> = [2, 4]
    @State private var startHour = 18
    @State private var endHour = 20
    @State private var hasEnd = false
    @State private var end = Date.now

    private let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("What is it", text: $title)
                Section("Days") {
                    ForEach(0..<7, id: \.self) { d in
                        Toggle(names[d], isOn: Binding(
                            get: { weekdays.contains(d) },
                            // Statements, not a ternary: insert returns a tuple and remove
                            // returns an optional, so they have no common type.
                            set: { on in
                                if on { weekdays.insert(d) } else { weekdays.remove(d) }
                            }))
                    }
                }
                Section("Time") {
                    Stepper("From \(startHour):00", value: $startHour, in: 0...23)
                    Stepper("Until \(endHour):00", value: $endHour, in: 1...23)
                }
                Section {
                    Toggle("It ends on a date", isOn: $hasEnd)
                    if hasEnd { DatePicker("Last week", selection: $end, displayedComponents: .date) }
                } footer: {
                    Text("A semester ends; a work shift usually doesn't.")
                }
            }
            .navigationTitle("Commitment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(Commitment(title: title, weekdays: weekdays.sorted(),
                                          startHour: startHour, endHour: endHour,
                                          untilISO: hasEnd ? AthleteProfile.iso(end) : nil))
                        dismiss()
                    }
                    .disabled(title.isEmpty || weekdays.isEmpty)
                }
            }
        }
    }
}

private struct BlackoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (Blackout) -> Void

    @State private var title = "Holiday"
    @State private var start = Date.now
    @State private var end = Date.now.addingTimeInterval(6 * 86_400)
    @State private var mode: Blackout.Mode = .easy

    var body: some View {
        NavigationStack {
            Form {
                TextField("What is it", text: $title)
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                Picker("While you're away", selection: $mode) {
                    ForEach(Blackout.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            .navigationTitle("Time away")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(Blackout(title: title, startISO: AthleteProfile.iso(start),
                                        endISO: AthleteProfile.iso(end), mode: mode))
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}

private struct EventEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (AthleteEvent) -> Void

    @State private var title = ""
    @State private var date = Date.now
    @State private var detail = ""
    @State private var isRace = true
    @State private var kind: EventKind?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $title)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Toggle("It's a race", isOn: $isRace)
                if isRace {
                    Picker("Distance", selection: $kind) {
                        Text("Not set").tag(EventKind?.none)
                        ForEach(EventKind.allCases.filter { $0 != .general }) { Text($0.label).tag(Optional($0)) }
                    }
                }
                TextField("Notes", text: $detail, axis: .vertical).lineLimit(2...5)
            }
            .navigationTitle("Race or event")
            .keyboardDismissible()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(AthleteEvent(dateISO: AthleteProfile.iso(date), title: title,
                                            detail: detail, isRace: isRace, kind: isRace ? kind : nil))
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}
