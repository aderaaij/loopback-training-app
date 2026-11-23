//
//  SetbackModels.swift
//  OpenHealthSync
//
//  Setbacks (server 0.1.25+): an illness or injury from its first day to the
//  day it is over, with how the athlete felt on the days in between. The
//  /api/setbacks endpoints are camelCase and speak calendar days (YYYY-MM-DD).
//

import Foundation

nonisolated enum SetbackKind: String, CaseIterable, Identifiable, Sendable {
    case illness
    case injury

    var id: String { rawValue }

    var label: String {
        switch self {
        case .illness: return "Illness"
        case .injury: return "Injury"
        }
    }

    /// "Sick since…" / "Injured since…"
    var adjective: String {
        switch self {
        case .illness: return "Sick"
        case .injury: return "Injured"
        }
    }

    var systemImage: String {
        switch self {
        case .illness: return "thermometer.medium"
        case .injury: return "bandage.fill"
        }
    }
}

nonisolated enum SetbackSeverity: String, CaseIterable, Identifiable, Sendable {
    case mild
    case moderate
    case severe

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    func explanation(for kind: SetbackKind) -> String {
        switch (self, kind) {
        case (.mild, _): return "You could still do an easy run."
        case (.moderate, _): return "No training for now."
        case (.severe, .illness): return "In bed, or a fever."
        case (.severe, .injury): return "Walking hurts."
        }
    }
}

nonisolated enum SetbackStatus: String, CaseIterable, Identifiable, Sendable {
    case worse
    case same
    case better
    case fine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .worse: return "Worse"
        case .same: return "Same"
        case .better: return "Better"
        case .fine: return "Fine"
        }
    }
}

/// A calendar day as the server sends it. Kept as its text so it can't drift
/// across a time zone; `date` places it in the device's calendar for display.
nonisolated struct SetbackDay: Sendable, Hashable, Comparable {
    let text: String

    init(text: String) {
        self.text = text
    }

    init(_ date: Date) {
        text = Self.formatter.string(from: date)
    }

    static var today: SetbackDay { SetbackDay(Date()) }

    /// Local midnight of this day.
    var date: Date { Self.formatter.date(from: text) ?? .distantPast }

    // YYYY-MM-DD sorts as text.
    static func < (lhs: SetbackDay, rhs: SetbackDay) -> Bool { lhs.text < rhs.text }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

nonisolated struct SetbackCheckin: Decodable, Sendable, Hashable, Identifiable {
    let day: SetbackDay
    /// Raw text, so a status a newer server adds still lists.
    let statusText: String
    let note: String?

    var id: String { day.text }
    var status: SetbackStatus? { SetbackStatus(rawValue: statusText) }

    private enum CodingKeys: String, CodingKey {
        case date, status, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = SetbackDay(text: try container.decode(String.self, forKey: .date))
        statusText = try container.decode(String.self, forKey: .status)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

/// The server's read of whether an open setback looks over (see the server's
/// setback_recovery.py). A suggestion only: the athlete decides.
nonisolated struct SetbackRecovery: Decodable, Sendable, Hashable {
    /// "looks_recovered", "not_yet" or "insufficient_data".
    let status: String
    /// One or two sentences saying why.
    let summary: String

    var looksRecovered: Bool { status == "looks_recovered" }
    var isNotYet: Bool { status == "not_yet" }
}

nonisolated struct Setback: Decodable, Sendable, Identifiable, Hashable {
    let id: UUID
    let kindText: String
    let severityText: String
    let start: SetbackDay
    /// Last day affected; nil while it is still going on.
    let end: SetbackDay?
    let bodyPart: String?
    let note: String?
    /// Oldest first.
    let checkins: [SetbackCheckin]
    /// Open setbacks only, and only from a server that computes it.
    let recovery: SetbackRecovery?

    var kind: SetbackKind { SetbackKind(rawValue: kindText) ?? .illness }
    var severity: SetbackSeverity { SetbackSeverity(rawValue: severityText) ?? .moderate }
    var isActive: Bool { end == nil }

    /// Days from the first through the last, or through today while open.
    /// Both ends count.
    var dayCount: Int {
        let last = end?.date ?? max(SetbackDay.today.date, start.date)
        let days = Calendar.current.dateComponents([.day], from: start.date, to: last).day ?? 0
        return max(days, 0) + 1
    }

    func checkin(on day: SetbackDay) -> SetbackCheckin? {
        checkins.first { $0.day == day }
    }

    /// "Illness", or "Left calf" for an injury that names one.
    var title: String {
        if kind == .injury, let bodyPart, !bodyPart.isEmpty { return bodyPart }
        return kind.label
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, severity, startDate, endDate, bodyPart, note, checkins, recovery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kindText = try container.decode(String.self, forKey: .kind)
        severityText = try container.decode(String.self, forKey: .severity)
        start = SetbackDay(text: try container.decode(String.self, forKey: .startDate))
        end = try container.decodeIfPresent(String.self, forKey: .endDate).map(SetbackDay.init(text:))
        bodyPart = try container.decodeIfPresent(String.self, forKey: .bodyPart)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        checkins = try container.decodeIfPresent([SetbackCheckin].self, forKey: .checkins) ?? []
        recovery = try? container.decodeIfPresent(SetbackRecovery.self, forKey: .recovery)
    }
}

/// What the athlete can set on a setback.
nonisolated struct SetbackDraft: Sendable, Equatable {
    var kind: SetbackKind
    var severity: SetbackSeverity
    var start: SetbackDay
    /// Nil = still going on.
    var end: SetbackDay?
    var bodyPart: String?
    var note: String?
}
