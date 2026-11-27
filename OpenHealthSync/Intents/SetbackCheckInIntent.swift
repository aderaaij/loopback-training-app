//
//  SetbackCheckInIntent.swift
//  OpenHealthSync
//
//  "I'm feeling better": today's check-in on an illness or injury that is
//  still going on, the one the Training tab's card files with its four
//  buttons. It never closes the setback; saying "fine" only points at the
//  button that does.
//

import AppIntents
import Foundation

extension SetbackStatus: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "How You Feel")

    static let caseDisplayRepresentations: [SetbackStatus: DisplayRepresentation] = [
        .worse: "Worse",
        .same: "Same",
        .better: "Better",
        .fine: "Fine",
    ]
}

struct SetbackCheckInIntent: AppIntent {
    static let title: LocalizedStringResource = "Setback Check-In"
    static let description = IntentDescription(
        "Records how you feel today while you're sick or injured, so your coach can follow along."
    )
    /// The answer names what you have, so not from a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "How You Feel", requestValueDialog: "How are you today?")
    var status: SetbackStatus

    static var parameterSummary: some ParameterSummary {
        Summary("Check in as \(\.$status)")
    }

    @Dependency private var session: SessionStore
    @Dependency private var setbackStore: SetbackStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard session.isAuthenticated else { throw LoopbackIntentError.notSignedIn }

        // Which setbacks are open is the server's to say, so there is no
        // answering this one offline.
        _ = try? await withTimeLimit(8) { await setbackStore.load() }
        guard setbackStore.loadState == .loaded else { throw LoopbackIntentError.serverUnreachable }

        let open = setbackStore.active
        let setback: Setback
        switch open.count {
        case 0:
            return .result(dialog: "You have no illness or injury on record.")
        case 1:
            setback = open[0]
        default:
            // An illness and an injury, or two injuries, can be open at once.
            let options = open.map { IntentChoiceOption(title: "\($0.title)") }
            let choice = try await requestChoice(between: options + [.cancel], dialog: "Which one?")
            guard let index = options.firstIndex(of: choice) else {
                return .result(dialog: "Nothing noted.")
            }
            setback = open[index]
        }

        do {
            try await withTimeLimit(10) { try await setbackStore.checkIn(setback, status: status) }
        } catch {
            throw LoopbackIntentError.serverUnreachable
        }

        let noted = "Noted for your \(setback.title.lowercased()): \(status.label.lowercased()) today."
        guard status == .fine else { return .result(dialog: "\(noted)") }
        return .result(dialog: "\(noted) If you're over it, mark yourself recovered in Loopback.")
    }
}
