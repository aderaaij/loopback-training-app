//
//  ShoesView.swift
//  OpenHealthSync
//
//  Shoe tracking: the list of pairs with their mileage (Settings → Shoes),
//  the add/edit form, and the picker shown on a workout's detail screen.
//

import SwiftUI

// MARK: - List

struct ShoesView: View {
    /// For the "update your server" explanation when the list can't load.
    let serverVersion: ServerVersion?

    @Environment(ShoeStore.self) private var store
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    @State private var showingAdd = false

    /// The first server release with /api/shoes.
    static let requiredServerVersion = ServerVersion(0, 1, 19)

    var body: some View {
        Form {
            switch store.loadState {
            case .idle, .loading:
                LBSection {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            case .failed:
                LBSection {
                    Text(failureMessage)
                        .font(.lbBody(.body))
                        .foregroundStyle(LB.textSecondary)
                    Button("Try Again") {
                        Task { await store.load() }
                    }
                }
            case .loaded:
                loadedSections
            }
        }
        .lbList()
        .navigationTitle("Shoes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.loadState == .loaded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add a pair", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                ShoeFormView(shoe: nil)
            }
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private var loadedSections: some View {
        if store.shoes.isEmpty {
            LBSection {
                Text("Add the shoes you run in to see how far each pair has gone.")
                    .font(.lbBody(.body))
                    .foregroundStyle(LB.textSecondary)
                Button("Add a Pair") { showingAdd = true }
            }
        } else {
            if !store.inUse.isEmpty {
                LBSection {
                    ForEach(store.inUse) { shoe in
                        NavigationLink {
                            ShoeFormView(shoe: shoe)
                        } label: {
                            ShoeRow(shoe: shoe, units: units)
                        }
                    }
                } header: {
                    Text("In use")
                } footer: {
                    Text("New runs go on the default pair. You can change the pair on any workout from its detail screen.")
                }
            }
            if !store.retired.isEmpty {
                LBSection("Retired") {
                    ForEach(store.retired) { shoe in
                        NavigationLink {
                            ShoeFormView(shoe: shoe)
                        } label: {
                            ShoeRow(shoe: shoe, units: units)
                        }
                    }
                }
            }
        }
    }

    private var failureMessage: String {
        if let serverVersion, serverVersion < Self.requiredServerVersion {
            return "Shoe tracking needs Loopback server v\(Self.requiredServerVersion) or newer. This server is running v\(serverVersion)."
        }
        return "Couldn't load your shoes. Check the connection to your server."
    }
}

// MARK: - Row

struct ShoeRow: View {
    let shoe: Shoe
    let units: DisplayUnits

    var body: some View {
        VStack(alignment: .leading, spacing: LB.Space.sm) {
            HStack(spacing: LB.Space.sm) {
                Text(shoe.name)
                    .font(.lbDisplay(.subheadline, .semibold))
                    .foregroundStyle(shoe.isRetired ? LB.textSecondary : LB.textPrimary)
                    .lineLimit(1)
                if shoe.isDefault {
                    LBStatusChip(text: "Default", color: LB.accent)
                }
                Spacer(minLength: 0)
            }

            Text(mileage)
                .font(.lbMono(.value))
                .foregroundStyle(LB.textTertiary)

            if let fraction = shoe.wornFraction, !shoe.isRetired {
                ProgressView(value: min(fraction, 1))
                    .tint(wearColor)
                    .accessibilityLabel("\(Int((fraction * 100).rounded())) percent of target")
                if let wearLabel {
                    Text(wearLabel)
                        .font(.lbBody(.secondary, .semibold))
                        .foregroundStyle(wearColor)
                }
            }
        }
        .padding(.vertical, LB.Space.xs)
    }

    private var mileage: String {
        let done = whole(shoe.distance)
        if let target = shoe.targetDistance {
            return "\(done) / \(whole(target)) \(units.distanceUnit)"
        }
        return "\(done) \(units.distanceUnit)"
    }

    private func whole(_ meters: Double) -> String {
        String(Int(units.distanceValue(meters: meters).rounded()))
    }

    private var wearColor: Color {
        switch shoe.wear {
        case .fine: return LB.green
        case .wearingOut: return LB.amber
        case .pastTarget: return LB.red
        }
    }

    private var wearLabel: String? {
        switch shoe.wear {
        case .fine: return nil
        case .wearingOut: return "Wearing out"
        case .pastTarget: return "Past its target"
        }
    }
}

// MARK: - Add / edit

struct ShoeFormView: View {
    /// Nil adds a new pair.
    let shoe: Shoe?

    @Environment(ShoeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault

    @State private var name = ""
    @State private var startText = ""
    @State private var targetText = ""
    @State private var isDefault = false
    @State private var didPrefill = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Form {
            LBSection {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
            } footer: {
                Text("For example the model and colour, so you can tell pairs apart.")
            }

            LBSection {
                distanceField("Starting mileage", text: $startText)
                distanceField("Target", text: $targetText)
            } footer: {
                Text("Starting mileage is what the pair had already done before you added it here. Leave the target empty for no target.")
            }

            if shoe?.isRetired != true {
                LBSection {
                    Toggle("Use for new runs", isOn: $isDefault)
                } footer: {
                    Text("New runs are put on this pair as they sync. Only one pair can be the default.")
                }
            }

            if let shoe {
                LBSection {
                    Button(shoe.isRetired ? "Bring Back into Use" : "Retire This Pair") {
                        run { try await store.setRetired(shoe, !shoe.isRetired) }
                    }
                    Button("Delete This Pair", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                } footer: {
                    Text("A retired pair keeps its workouts and mileage. Deleting a pair leaves its workouts without one.")
                }
            }

            if let errorMessage {
                LBSection {
                    Text(errorMessage)
                        .font(.lbBody(.body))
                        .foregroundStyle(LB.red)
                }
            }
        }
        .lbList()
        .navigationTitle(shoe == nil ? "New Pair" : "Edit Pair")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if shoe == nil {
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
            "Delete this pair?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let shoe { run { try await store.delete(shoe) } }
            }
        } message: {
            Text("Its workouts stay, without a pair. This can't be undone.")
        }
        .disabled(isSaving)
        .onAppear(perform: prefill)
    }

    private func distanceField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
            Text(units.distanceUnit)
                .foregroundStyle(LB.textTertiary)
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let shoe {
            name = shoe.name
            startText = Self.text(units.distanceValue(meters: shoe.startDistance))
            targetText = shoe.targetDistance.map { Self.text(units.distanceValue(meters: $0)) } ?? ""
            isDefault = shoe.isDefault
        } else {
            // A common lifetime for a running shoe.
            targetText = units == .imperial ? "500" : "800"
            isDefault = store.inUse.isEmpty
        }
    }

    /// What Save would send; nil while the form isn't valid.
    private var draft: ShoeDraft? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let start = Self.number(startText, emptyAs: 0), start >= 0 else { return nil }
        var target: Double?
        if !targetText.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = Self.number(targetText, emptyAs: nil), value > 0 else { return nil }
            target = value
        }
        return ShoeDraft(
            name: trimmed,
            startDistance: units.meters(fromDistanceValue: start),
            targetDistance: target.map(units.meters(fromDistanceValue:)),
            isDefault: isDefault && shoe?.isRetired != true
        )
    }

    private func save() {
        guard let draft else { return }
        run {
            if let shoe {
                try await store.update(shoe, with: draft)
            } else {
                try await store.add(draft)
            }
        }
    }

    /// Runs a change against the server and leaves the form when it lands.
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

    /// Accepts a decimal comma as well as a point.
    private static func number(_ text: String, emptyAs fallback: Double?) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return fallback }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    private static func text(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

// MARK: - Workout detail section

/// "Shoes" card on a workout's detail screen: shows the pair and lets the
/// athlete change it. The parent loads the workout's pair with
/// `load(workoutId:activityType:store:)` and shows this only when that
/// returns something, so a view that renders nothing never has to load.
struct WorkoutShoeSection: View {
    let workoutId: UUID
    /// The pair the server had on the workout when the screen loaded.
    let initial: WorkoutShoe

    @Environment(ShoeStore.self) private var store
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    @State private var selectedId: UUID?
    @State private var didSeed = false
    @State private var failed = false
    @State private var isConfirming = false

    /// The workout's pair, or nil when there is nothing to show: not a
    /// foot-based activity, no pairs added yet, the workout isn't on the
    /// server, or the server predates shoe tracking.
    static func load(workoutId: UUID, activityType: String, store: ShoeStore) async -> WorkoutShoe? {
        guard ["running", "walking", "hiking"].contains(activityType) else { return nil }
        if store.loadState != .loaded { await store.load() }
        guard !store.shoes.isEmpty else { return nil }
        return await store.workoutShoe(workoutId: workoutId)
    }

    var body: some View {
        Group {
            if !store.shoes.isEmpty {
                LBDetailSection(title: "Shoes") {
                    VStack(alignment: .leading, spacing: LB.Space.sm) {
                        Menu {
                            Picker("Shoes", selection: selection) {
                                Text("None").tag(UUID?.none)
                                ForEach(choices) { shoe in
                                    Text(shoe.name).tag(UUID?.some(shoe.id))
                                }
                            }
                        } label: {
                            HStack {
                                Text(store.shoe(id: selectedId)?.name ?? "None")
                                    .font(.lbBody(.body, .semibold))
                                    .foregroundStyle(LB.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(LB.textTertiary)
                            }
                        }

                        if let shoe = store.shoe(id: selectedId) {
                            Text("\(Int(units.distanceValue(meters: shoe.distance).rounded())) \(units.distanceUnit) on this pair")
                                .font(.lbMono(.caption))
                                .foregroundStyle(LB.textTertiary)
                        }
                        if store.needsCheck(workoutId: workoutId) {
                            checkPrompt
                        }
                        if failed {
                            Text("Couldn't change the pair. Try again.")
                                .font(.lbBody(.secondary))
                                .foregroundStyle(LB.red)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            selectedId = initial.shoeId
        }
    }

    /// Shown while the run still has the pair it got automatically.
    private var checkPrompt: some View {
        VStack(alignment: .leading, spacing: LB.Space.sm) {
            Text(selectedId == nil
                 ? "No pair on this run yet. Which one did you wear?"
                 : "Added automatically. Is this the pair you wore?")
                .font(.lbBody(.secondary))
                .foregroundStyle(LB.textSecondary)

            Button {
                confirm()
            } label: {
                Text(selectedId == nil ? "None of these" : "Yes, this pair")
                    .font(.lbBody(.secondary, .semibold))
                    .foregroundStyle(LB.accent)
                    .padding(.horizontal, LB.Space.md)
                    .padding(.vertical, LB.Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                            .fill(LB.accentTint())
                    )
            }
            .buttonStyle(.plain)
            .disabled(isConfirming)
        }
        .padding(.top, LB.Space.xxs)
    }

    /// Keeps the pair as it is and records that the athlete looked at it.
    private func confirm() {
        isConfirming = true
        failed = false
        Task {
            do {
                try await store.assign(shoeId: selectedId, toWorkout: workoutId)
            } catch {
                failed = true
            }
            isConfirming = false
        }
    }

    /// Pairs in use, plus the one already on this workout if it is retired.
    private var choices: [Shoe] {
        store.shoes.filter { !$0.isRetired || $0.id == selectedId }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { selectedId },
            set: { newValue in
                let previous = selectedId
                guard newValue != previous else { return }
                selectedId = newValue
                failed = false
                Task {
                    do {
                        try await store.assign(shoeId: newValue, toWorkout: workoutId)
                    } catch {
                        selectedId = previous
                        failed = true
                    }
                }
            }
        )
    }
}
