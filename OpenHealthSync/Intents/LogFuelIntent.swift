//
//  LogFuelIntent.swift
//  OpenHealthSync
//
//  "Log a gel on my last run": adds one of the athlete's saved products to
//  the fuelling log of the latest run in Health, the log the run's own
//  screen shows. A gel is an entry a piece; a drink is one entry with the
//  total, so more of the same drink is added to it. Where in the run a gel
//  was taken can be filled in on the run's screen afterwards.
//
//  Fuelling goes to the coach under Nutrition, so nothing is offered or
//  logged for an athlete who doesn't share that.
//

import AppIntents
import Foundation

// MARK: - A saved product, as Siri and Shortcuts see it

struct FuelProductEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fuel Product")
    static let defaultQuery = FuelProductQuery()

    let id: UUID

    @Property(title: "Name")
    var name: String

    /// "Gel · 25 g carbs"
    let detail: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)", image: .init(systemName: symbol))
    }

    init(_ product: FuelProduct) {
        id = product.id
        detail = [product.kind.label, FuelFormat.figures(carbsG: product.carbsG, caffeineMg: product.caffeineMg)]
            .compactMap { $0 }
            .joined(separator: " · ")
        symbol = product.kind.symbol
        name = product.name
    }
}

struct FuelProductQuery: EntityStringQuery {
    @Dependency private var fuelStore: FuelStore

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [FuelProductEntity] {
        await products().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [FuelProductEntity] {
        await products().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [FuelProductEntity] {
        await products()
    }

    /// Empty for an athlete who doesn't share Nutrition, and while the
    /// server can't be reached.
    @MainActor
    private func products() async -> [FuelProductEntity] {
        guard DataConsent.current.contains(.nutrition) else { return [] }
        _ = try? await withTimeLimit(5) { await fuelStore.loadIfNeeded() }
        return fuelStore.products.map(FuelProductEntity.init)
    }
}

// MARK: - The action

struct LogFuelIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Fuel"
    static let description = IntentDescription(
        "Adds one of your saved gels, drinks or other fuel to the log of your latest run."
    )
    /// It reads the latest run from Health, which a locked phone can't.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Product", description: "One of the products saved under Fuelling in Loopback's settings.")
    var product: FuelProductEntity?

    @Parameter(
        title: "How Many",
        description: "Pieces of a gel or anything else; servings of a drink.",
        default: 1,
        inclusiveRange: (1, 10)
    )
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$count) of \(\.$product) on the last run")
    }

    @Dependency private var session: SessionStore
    @Dependency private var workoutManager: WorkoutManager
    @Dependency private var fuelStore: FuelStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard session.isAuthenticated else { throw LoopbackIntentError.notSignedIn }
        guard DataConsent.current.contains(.nutrition) else { throw LoopbackIntentError.fuellingNotShared }

        _ = try? await withTimeLimit(8) { await fuelStore.loadIfNeeded() }
        guard fuelStore.loadState == .loaded else { throw LoopbackIntentError.serverUnreachable }
        guard !fuelStore.products.isEmpty else {
            return .result(dialog: "You have no fuel saved yet. Add a gel or a drink under Fuelling in Loopback's settings.")
        }
        let picked: FuelProductEntity
        if let product {
            picked = product
        } else {
            picked = try await $product.requestDisambiguation(
                among: fuelStore.products.map(FuelProductEntity.init),
                dialog: "What did you take?"
            )
        }
        guard let chosen = fuelStore.products.first(where: { $0.id == picked.id }) else {
            throw LoopbackIntentError.productNotFound
        }

        let run: WorkoutSummary?
        do {
            run = try await workoutManager.latestRun()
        } catch {
            throw LoopbackIntentError.healthUnreadable
        }
        guard let run else {
            return .result(dialog: "There are no runs in Health yet.")
        }
        // The log hangs on the run as the server has it.
        guard workoutManager.hasSentWorkout(run.id) else { throw LoopbackIntentError.runNotOnServer }

        let saved: WorkoutFuel
        do {
            saved = try await withTimeLimit(15) {
                guard let current = try await fuelStore.loadWorkoutFuel(workoutId: run.id) else {
                    throw LoopbackIntentError.runNotOnServer
                }
                // The server takes the whole log, so the new entries go in
                // with the ones it already has.
                guard let entries = current.entries.map(\.draft).adding(chosen, count: count) else {
                    throw LoopbackIntentError.noServingSize(chosen.name)
                }
                return try await fuelStore.setWorkoutFuel(workoutId: run.id, entries: entries)
            }
        } catch let error as LoopbackIntentError {
            throw error
        } catch {
            throw LoopbackIntentError.serverUnreachable
        }

        let what = count == 1 ? chosen.name : "\(count) × \(chosen.name)"
        let logged = "Logged \(what) on your run \(IntentPhrasing.whenPast(run.startDate))."
        guard let total = Self.spoken(saved.summary) else {
            return .result(dialog: "\(logged)")
        }
        return .result(dialog: "\(logged) That run now has \(total).")
    }

    /// "30 g carbs at 57.4 g an hour, 1 L and 100 mg caffeine": the run's
    /// totals as part of a sentence. The card's own line separates them with
    /// dots and writes "g/h", which read badly aloud.
    private static func spoken(_ summary: FuelSummary) -> String? {
        var parts: [String] = []
        if summary.carbsG > 0 {
            let rate = summary.carbsPerHourG.map { " at \(FuelFormat.number($0)) g an hour" } ?? ""
            parts.append("\(FuelFormat.number(summary.carbsG)) g carbs\(rate)")
        }
        if summary.volumeMl > 0 { parts.append(FuelFormat.volume(summary.volumeMl)) }
        if summary.caffeineMg > 0 { parts.append("\(FuelFormat.number(summary.caffeineMg)) mg caffeine") }
        return parts.isEmpty ? nil : parts.formatted(.list(type: .and))
    }
}
