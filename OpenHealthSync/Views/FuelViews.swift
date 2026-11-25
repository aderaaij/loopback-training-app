//
//  FuelViews.swift
//  OpenHealthSync
//
//  Fuelling: the saved products (Settings → Fuelling), the sheet that adds
//  or changes one entry, and the two cards built on it: what was taken on a
//  workout, and the plan on a session ahead.
//
//  Shown only to an athlete who shares Nutrition, because that is the
//  category the coach reads it under.
//

import SwiftUI

// MARK: - Formatting

nonisolated enum FuelFormat {
    /// At most one decimal, none when it would be a zero: "30", "7.5".
    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// "500 ml", and "1.5 L" from a liter on.
    static func volume(_ ml: Double) -> String {
        ml >= 1000 ? "\(number(ml / 1000)) L" : "\(number(ml)) ml"
    }

    /// "30 g carbs · 100 mg caffeine", leaving out what is unknown or zero.
    static func figures(carbsG: Double?, caffeineMg: Double?) -> String? {
        var parts: [String] = []
        if let carbsG, carbsG > 0 { parts.append("\(number(carbsG)) g carbs") }
        if let caffeineMg, caffeineMg > 0 { parts.append("\(number(caffeineMg)) mg caffeine") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "100 g carbs · 50 g/h · 1 L · 100 mg caffeine", nil for nothing at all.
    static func summary(_ summary: FuelSummary) -> String? {
        var parts: [String] = []
        if summary.carbsG > 0 {
            parts.append("\(number(summary.carbsG)) g carbs")
            if let rate = summary.carbsPerHourG { parts.append("\(number(rate)) g/h") }
        }
        if summary.volumeMl > 0 { parts.append(volume(summary.volumeMl)) }
        if summary.caffeineMg > 0 { parts.append("\(number(summary.caffeineMg)) mg caffeine") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Accepts a decimal comma as well as a point; nil for empty or junk.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    static func text(_ value: Double?) -> String {
        value.map(number) ?? ""
    }
}

// MARK: - Settings: saved products

struct FuelProductsView: View {
    /// For the "update your server" explanation when the list can't load.
    let serverVersion: ServerVersion?

    @Environment(FuelStore.self) private var store
    @State private var showingAdd = false

    /// The first server release with /api/fuel.
    static let requiredServerVersion = ServerVersion(0, 1, 27)

    var body: some View {
        Form {
            switch store.loadState {
            case .idle, .loading:
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            case .failed:
                Section {
                    Text(failureMessage)
                        .font(.lbBody(14))
                        .foregroundStyle(LB.textSecondary)
                    Button("Try Again") {
                        Task { await store.load() }
                    }
                }
            case .loaded:
                loadedSections
            }
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle("Fuelling")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.loadState == .loaded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add a product", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                FuelProductFormView(product: nil)
            }
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private var loadedSections: some View {
        if store.products.isEmpty {
            Section {
                Text("Save the drinks and gels you take on runs. Logging one after a run, or planning one for a long run, is then a matter of picking it.")
                    .font(.lbBody(14))
                    .foregroundStyle(LB.textSecondary)
                Button("Add a Product") { showingAdd = true }
            }
        } else {
            section("Drinks", store.drinks)
            section("Gels and food", store.items)
            Section {
            } footer: {
                Text("Log what you took from a workout's screen, and plan a run from the session's screen. Your coach sees both while you share Nutrition.")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ products: [FuelProduct]) -> some View {
        if !products.isEmpty {
            Section(title) {
                ForEach(products) { product in
                    NavigationLink {
                        FuelProductFormView(product: product)
                    } label: {
                        FuelProductRow(product: product)
                    }
                }
            }
        }
    }

    private var failureMessage: String {
        if let serverVersion, serverVersion < Self.requiredServerVersion {
            return "Fuelling needs Loopback server v\(Self.requiredServerVersion) or newer. This server is running v\(serverVersion)."
        }
        return "Couldn't load your products. Check the connection to your server."
    }
}

struct FuelProductRow: View {
    let product: FuelProduct
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.lbDisplay(15, .semibold))
                    .foregroundStyle(LB.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LB.accent)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var detail: String? {
        var parts: [String] = []
        if product.kind == .drink, let volume = product.volumeMl {
            parts.append("per \(FuelFormat.volume(volume))")
        }
        if let figures = FuelFormat.figures(carbsG: product.carbsG, caffeineMg: product.caffeineMg) {
            parts.append(figures)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct FuelProductFormView: View {
    /// Nil adds a new product.
    let product: FuelProduct?

    @Environment(FuelStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: FuelKind = .gel
    @State private var volumeText = ""
    @State private var carbsText = ""
    @State private var caffeineText = ""
    @State private var didPrefill = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.sentences)
                Picker("Kind", selection: $kind) {
                    ForEach(FuelKind.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(kind == .drink
                     ? "A drink is logged as the total you drank on a run."
                     : "Logged one at a time, with where in the run you took it.")
            }

            Section {
                if kind == .drink {
                    numberField("Serving", text: $volumeText, unit: "ml")
                }
                numberField("Carbohydrates", text: $carbsText, unit: "g")
                numberField("Caffeine", text: $caffeineText, unit: "mg")
            } footer: {
                Text(kind == .drink
                     ? "Carbohydrates and caffeine in one serving, such as a 500 ml bottle. Leave empty what you don't know."
                     : "In one of them. Leave empty what you don't know.")
            }

            if product != nil {
                Section {
                    Button("Delete This Product", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                } footer: {
                    Text("What you logged or planned with it stays as it is.")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.lbBody(14))
                        .foregroundStyle(LB.red)
                }
            }
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle(product == nil ? "New Product" : "Edit Product")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if product == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(draft == nil || isSaving)
            }
        }
        .confirmationDialog(
            "Delete this product?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let product { run { try await store.delete(product) } }
            }
        }
        .disabled(isSaving)
        .onAppear(perform: prefill)
    }

    private func numberField(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("–", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
            Text(unit)
                .foregroundStyle(LB.textTertiary)
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let product else { return }
        name = product.name
        kind = product.kind
        volumeText = FuelFormat.text(product.volumeMl)
        carbsText = FuelFormat.text(product.carbsG)
        caffeineText = FuelFormat.text(product.caffeineMg)
    }

    /// Nil while the name is empty or a filled-in figure is not a number.
    private var draft: FuelProductDraft? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var figures: [Double?] = []
        for text in [volumeText, carbsText, caffeineText] {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                figures.append(nil)
            } else if let value = FuelFormat.parse(text), value >= 0 {
                figures.append(value)
            } else {
                return nil
            }
        }
        let volume = kind == .drink ? figures[0] : nil
        if let volume, volume <= 0 { return nil }
        return FuelProductDraft(
            name: trimmed, kind: kind, volumeMl: volume, carbsG: figures[1], caffeineMg: figures[2]
        )
    }

    private func save() {
        guard let draft else { return }
        run {
            if let product {
                try await store.update(product, with: draft)
            } else {
                try await store.add(draft)
            }
        }
    }

    private func run(_ change: @escaping () async throws -> Void) {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await change()
                dismiss()
            } catch {
                errorMessage = "Couldn't save. Check the connection to your server and try again."
            }
            isSaving = false
        }
    }
}

// MARK: - One entry

/// A line in a fuelling list: what, how much or where, and what was in it.
struct FuelEntryRow: View {
    let entry: FuelEntry
    let units: DisplayUnits
    /// Planned rather than taken: shown a step quieter.
    var muted = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(muted ? LB.textTertiary : LB.green)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LB.surfaceTile)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.lbBody(14, .semibold))
                    .foregroundStyle(muted ? LB.textBright : LB.textPrimary)
                    .lineLimit(1)
                if let figures = FuelFormat.figures(carbsG: entry.carbsG, caffeineMg: entry.caffeineMg) {
                    Text(figures)
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.lbMono(13))
                    .foregroundStyle(muted ? LB.textSecondary : LB.textPrimary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// A drink's amount; for anything else, where it was taken.
    private var trailing: String? {
        if entry.kind == .drink {
            return entry.volumeMl.map(FuelFormat.volume)
        }
        return entry.atDistance.map {
            "\(FuelFormat.number(units.distanceValue(meters: $0))) \(units.distanceUnit)"
        }
    }
}

/// Adds one entry to a list, or changes one that is there.
struct FuelEntrySheet: View {
    /// Nil adds a new entry.
    let entry: FuelEntry?
    /// "taken" on a workout, "planned" on a session; only wording differs.
    let isPlan: Bool
    let onSave: (FuelEntryDraft) -> Void
    let onDelete: (() -> Void)?

    @Environment(FuelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault

    /// The saved product picked; nil is "something else", typed in by hand.
    @State private var productId: UUID?
    @State private var name = ""
    @State private var kind: FuelKind = .gel
    @State private var volumeText = ""
    @State private var positionText = ""
    @State private var carbsText = ""
    @State private var caffeineText = ""
    @State private var didPrefill = false
    /// The position as first shown, to tell an untouched field from an edit.
    @State private var shownPositionText = ""

    private var product: FuelProduct? {
        guard entry == nil, let productId else { return nil }
        return store.products.first { $0.id == productId }
    }

    /// With a product picked, its figures are used; otherwise they are typed.
    private var typesFigures: Bool { product == nil }

    private var effectiveKind: FuelKind { product?.kind ?? kind }

    var body: some View {
        Form {
            if entry == nil {
                pickSection
            }

            if typesFigures {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.sentences)
                    if entry == nil {
                        Picker("Kind", selection: $kind) {
                            ForEach(FuelKind.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }

            Section {
                if effectiveKind == .drink {
                    numberField("Amount", text: $volumeText, unit: "ml")
                } else {
                    numberField(isPlan ? "Take at" : "Taken at", text: $positionText, unit: units.distanceUnit)
                }
                if typesFigures {
                    numberField("Carbohydrates", text: $carbsText, unit: "g")
                    numberField("Caffeine", text: $caffeineText, unit: "mg")
                }
            } footer: {
                Text(footer)
            }

            if let onDelete {
                Section {
                    Button("Remove", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle(entry == nil ? (isPlan ? "Add to Plan" : "Add to Log") : entry?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(entry == nil ? "Add" : "Save") {
                    if let draft {
                        onSave(draft)
                        dismiss()
                    }
                }
                .disabled(draft == nil)
            }
        }
        .task {
            await store.loadIfNeeded()
            prefill()
        }
    }

    @ViewBuilder
    private var pickSection: some View {
        Section {
            ForEach(store.products) { product in
                Button {
                    select(product)
                } label: {
                    FuelProductRow(product: product, isSelected: productId == product.id)
                }
                .buttonStyle(.plain)
            }
            Button {
                productId = nil
            } label: {
                HStack {
                    Text("Something else")
                        .font(.lbDisplay(15, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    Spacer()
                    if productId == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LB.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            if store.products.isEmpty {
                Text("Save the drinks and gels you use under Settings → Fuelling to pick them here.")
            }
        }
    }

    private func numberField(_ label: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("–", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
            Text(unit)
                .foregroundStyle(LB.textTertiary)
        }
    }

    private var footer: String {
        if effectiveKind == .drink {
            if let product, let serving = product.volumeMl, product.carbsG != nil || product.caffeineMg != nil {
                return "The total over the run. Carbohydrates and caffeine follow from the \(FuelFormat.volume(serving)) serving."
            }
            return isPlan ? "The total to drink over the run." : "The total you drank over the run."
        }
        let each = entry == nil ? " Add one entry for each." : ""
        return isPlan
            ? "How far into the run to take it.\(each)"
            : "How far into the run you took it. Leave empty if you don't remember.\(each)"
    }

    private func select(_ product: FuelProduct) {
        productId = product.id
        if product.kind == .drink, FuelFormat.parse(volumeText) == nil {
            volumeText = FuelFormat.text(product.volumeMl)
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let entry {
            name = entry.name
            kind = entry.kind
            volumeText = FuelFormat.text(entry.volumeMl)
            positionText = FuelFormat.text(entry.atDistance.map { units.distanceValue(meters: $0) })
            shownPositionText = positionText
            carbsText = FuelFormat.text(entry.carbsG)
            caffeineText = FuelFormat.text(entry.caffeineMg)
        } else if let first = store.products.first(where: { $0.kind != .drink }) ?? store.products.first {
            // Gels are what gets added most; start there.
            select(first)
        }
    }

    /// An empty field is "none"; a field with something that is not a
    /// number, or is negative, blocks saving.
    private func optional(_ text: String) -> Double?? {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .some(nil) }
        guard let value = FuelFormat.parse(text), value >= 0 else { return nil }
        return .some(value)
    }

    private var draft: FuelEntryDraft? {
        let isDrink = effectiveKind == .drink
        guard let volume = optional(isDrink ? volumeText : ""),
              let position = optional(isDrink ? "" : positionText) else { return nil }
        if isDrink, (volume ?? 0) <= 0 { return nil }
        // Shown to one decimal in the athlete's unit; a field left alone
        // keeps the meters it had rather than that rounding.
        let atDistance = entry != nil && positionText == shownPositionText
            ? entry?.atDistance
            : position.map { units.meters(fromDistanceValue: $0) }

        if let product {
            var draft = FuelEntryDraft(product: product)
            draft.atDistance = atDistance
            if isDrink, let volume {
                // A drink's figures are per serving, so they follow the amount.
                let share = product.volumeMl.map { $0 > 0 ? volume / $0 : 1 } ?? 1
                draft.volumeMl = volume
                draft.carbsG = product.carbsG.map { ($0 * share * 10).rounded() / 10 }
                draft.caffeineMg = product.caffeineMg.map { ($0 * share * 10).rounded() / 10 }
            }
            return draft
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let carbs = optional(carbsText),
              let caffeine = optional(caffeineText) else { return nil }
        return FuelEntryDraft(
            productId: entry?.productId, name: trimmed, kind: effectiveKind,
            volumeMl: volume, carbsG: carbs, caffeineMg: caffeine, atDistance: atDistance
        )
    }
}

// MARK: - The list inside a card

/// Which entry the sheet is open on.
private enum FuelSheetTarget: Identifiable {
    case add
    case edit(FuelEntry)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let entry): entry.id.uuidString
        }
    }
}

private struct FuelPillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.lbBody(13, .semibold))
                .foregroundStyle(LB.accent)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                        .fill(LB.accentTint())
                )
        }
        .buttonStyle(.plain)
    }
}

/// Entries that can be tapped to change, their totals, and an Add button.
/// The owner says how a changed list is saved.
private struct FuelEditableList: View {
    let entries: [FuelEntry]
    let summary: FuelSummary
    let isPlan: Bool
    let emptyText: String
    let isSaving: Bool
    /// Sends the whole list as it should now be.
    let save: ([FuelEntryDraft]) -> Void

    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    @State private var sheet: FuelSheetTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entries.isEmpty {
                Text(emptyText)
                    .font(.lbBody(13))
                    .foregroundStyle(LB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries) { entry in
                    Button {
                        sheet = .edit(entry)
                    } label: {
                        FuelEntryRow(entry: entry, units: units)
                    }
                    .buttonStyle(.plain)
                }
                if let line = FuelFormat.summary(summary) {
                    Text(line)
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textSecondary)
                }
            }

            FuelPillButton(title: "Add", systemImage: "plus") { sheet = .add }
                .disabled(isSaving)
        }
        .sheet(item: $sheet) { target in
            NavigationStack {
                switch target {
                case .add:
                    FuelEntrySheet(entry: nil, isPlan: isPlan, onSave: { draft in
                        save(entries.map(\.draft) + [draft])
                    }, onDelete: nil)
                case .edit(let entry):
                    FuelEntrySheet(entry: entry, isPlan: isPlan, onSave: { draft in
                        save(entries.map { $0.id == entry.id ? draft : $0.draft })
                    }, onDelete: {
                        save(entries.filter { $0.id != entry.id }.map(\.draft))
                    })
                }
            }
        }
    }
}

// MARK: - Workout detail section

/// "Fuelling" card on a workout's detail screen: what was drunk and eaten,
/// and below it the plan the session had, which one tap logs as taken. The
/// parent loads the workout's fuelling and shows this only when that returns
/// something.
struct WorkoutFuelSection: View {
    let workoutId: UUID
    /// What the server had when the screen loaded.
    let initial: WorkoutFuel

    @Environment(FuelStore.self) private var store
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    @State private var fuel: WorkoutFuel?
    @State private var isSaving = false
    @State private var failed = false

    private var current: WorkoutFuel { fuel ?? initial }

    var body: some View {
        LBDetailSection(title: "Fuelling", trailing: trailing) {
            VStack(alignment: .leading, spacing: 14) {
                FuelEditableList(
                    entries: current.entries,
                    summary: current.summary,
                    isPlan: false,
                    emptyText: current.planned.isEmpty
                        ? "Nothing logged for this workout. Add what you drank and ate, and your coach can read how it was fuelled."
                        : "Nothing logged yet.",
                    isSaving: isSaving,
                    save: save
                )

                if !current.planned.isEmpty {
                    plannedBlock
                }

                if failed {
                    Text("Couldn't save. Check the connection to your server and try again.")
                        .font(.lbBody(12))
                        .foregroundStyle(LB.red)
                }
            }
        }
    }

    /// Carbohydrates per hour, the figure a long run is judged on.
    private var trailing: String? {
        guard let rate = current.summary.carbsPerHourG, current.summary.carbsG > 0 else { return nil }
        return "\(FuelFormat.number(rate)) G/H"
    }

    private var plannedBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(LB.line)
                .frame(height: 1)

            Text("PLANNED")
                .font(.lbBody(11, .bold))
                .tracking(0.4)
                .foregroundStyle(LB.textTertiary)

            ForEach(current.planned) { entry in
                FuelEntryRow(entry: entry, units: units, muted: true)
            }
            if let summary = current.plannedSummary, let line = FuelFormat.summary(summary) {
                Text(line)
                    .font(.lbMono(11))
                    .foregroundStyle(LB.textTertiary)
            }

            if current.entries.isEmpty {
                FuelPillButton(title: "Log as planned", systemImage: "checkmark") {
                    save(current.planned.map(\.draft))
                }
                .disabled(isSaving)
            }
        }
    }

    private func save(_ entries: [FuelEntryDraft]) {
        isSaving = true
        failed = false
        Task {
            do {
                fuel = try await store.setWorkoutFuel(workoutId: workoutId, entries: entries)
            } catch {
                failed = true
            }
            isSaving = false
        }
    }
}

// MARK: - Session detail section

/// "Fuelling plan" card on a planned session: what to drink and eat on the
/// run, written by the coach or by the athlete here.
struct SessionFuelSection: View {
    let sessionId: UUID
    let initial: SessionFuel

    @Environment(FuelStore.self) private var store
    @State private var plan: SessionFuel?
    @State private var isSaving = false
    @State private var failed = false

    private var current: SessionFuel { plan ?? initial }

    var body: some View {
        LBDetailSection(title: "Fuelling plan") {
            VStack(alignment: .leading, spacing: 14) {
                FuelEditableList(
                    entries: current.entries,
                    summary: current.summary,
                    isPlan: true,
                    emptyText: "No plan for this run yet. Ask your coach for one, or add what you mean to take.",
                    isSaving: isSaving,
                    save: save
                )
                if failed {
                    Text("Couldn't save. Check the connection to your server and try again.")
                        .font(.lbBody(12))
                        .foregroundStyle(LB.red)
                }
            }
        }
    }

    private func save(_ entries: [FuelEntryDraft]) {
        isSaving = true
        failed = false
        Task {
            do {
                plan = try await store.setSessionFuel(sessionId: sessionId, entries: entries)
            } catch {
                failed = true
            }
            isSaving = false
        }
    }
}
