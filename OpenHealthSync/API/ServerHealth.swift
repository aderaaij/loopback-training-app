//
//  ServerHealth.swift
//  OpenHealthSync
//
//  The server-version handshake. `GET /api/health` is unauthenticated (it
//  works before login), reports the server's identity, database health, and
//  SemVer version, and this file turns that into a compatibility verdict the
//  UI can act on — graceful degradation instead of mystery failures when the
//  app and server drift, modeled on Audiobookshelf's client version checks.
//
//  Marked `nonisolated` because the project defaults types to @MainActor
//  (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor); `ServerHealth` is decoded on
//  the WorkoutAPIClient actor and crosses back to the main actor, so it (and
//  the types it exposes) must be actor-agnostic and Sendable.
//

import Foundation

/// A parsed SemVer triple. Comparisons are used for the compatibility gate.
nonisolated struct ServerVersion: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "0.1.0" (tolerating a leading `v` and any `-prerelease`/`+build`
    /// suffix). Missing components default to 0; returns nil only when there's
    /// no leading numeric major.
    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let unprefixed = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        // SemVer metadata lives after the first '-' or '+'; drop it.
        let core = unprefixed.split(whereSeparator: { $0 == "-" || $0 == "+" })
            .first.map(String.init) ?? unprefixed
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        self.init(major, minor, patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The `/api/health` payload: `{ "service": "training-api", "version": "0.1.0",
/// "database": "ok" }`.
nonisolated struct ServerHealth: Decodable, Sendable {
    let service: String
    let version: String
    let database: String

    /// A real Loopback server always answers with this service name; anything
    /// else means "wrong URL / some other server answered".
    var isLoopbackServer: Bool { service == "training-api" }

    /// `database` is "ok" or "error" (server up but DB unreachable).
    var databaseOK: Bool { database.caseInsensitiveCompare("ok") == .orderedSame }

    /// The reported version, parsed; nil if the server sent something we can't
    /// read as SemVer.
    var semanticVersion: ServerVersion? { ServerVersion(version) }
}

/// The verdict of comparing a server's version against what this app build
/// supports. Never blocking — the UI warns and lets the user proceed.
nonisolated enum ServerCompatibility: Sendable, Equatable {
    /// Version is in the supported range.
    case compatible
    /// No usable version (old server without `/api/health`, unreachable, or an
    /// unparseable version). Treated as "proceed, can't say".
    case unknown
    /// Server is behind the minimum — the actionable "update the server" case.
    case serverTooOld(current: ServerVersion, minimum: ServerVersion)
    /// Server is ahead of what this build knows — usually the softer "update
    /// the app" note, tinted as a warning when it's a whole major ahead.
    case serverNewer(current: ServerVersion, appSupports: ServerVersion)

    /// Oldest server this app can talk to. 0.x rule: a minor bump (0.1 → 0.2)
    /// is a breaking wire change, so the gate compares on minor, not patch.
    static let minimumServerVersion = ServerVersion(0, 1, 0)
    /// Newest server line this build was written against. A server minor above
    /// this only earns the soft "app is behind" note.
    static let latestKnownServerVersion = ServerVersion(0, 1, 0)

    static func evaluate(_ version: ServerVersion?) -> ServerCompatibility {
        guard let version else { return .unknown }
        let minimum = minimumServerVersion
        let known = latestKnownServerVersion
        // Compare on major.minor only — patch releases never break the wire
        // contract, so they never warn.
        if (version.major, version.minor) < (minimum.major, minimum.minor) {
            return .serverTooOld(current: version, minimum: minimum)
        }
        if (version.major, version.minor) > (known.major, known.minor) {
            return .serverNewer(current: version, appSupports: known)
        }
        return .compatible
    }

    var isWarning: Bool {
        switch self {
        case .serverTooOld, .serverNewer: return true
        case .compatible, .unknown: return false
        }
    }

    /// The cases the UI tints as warnings: a server behind the minimum, or one
    /// a full major ahead — certainly a breaking wire change under the same
    /// rules that make a minor bump breaking. A minor-ahead server keeps the
    /// quieter "app is behind" note.
    var isSevere: Bool {
        switch self {
        case .serverTooOld:
            return true
        case let .serverNewer(current, appSupports):
            return current.major > appSupports.major
        case .compatible, .unknown:
            return false
        }
    }

    /// User-facing copy; nil when there's nothing to warn about.
    var message: String? {
        switch self {
        case .compatible, .unknown:
            return nil
        case let .serverTooOld(current, minimum):
            return "This server is running v\(current). Loopback needs v\(minimum) or newer — update the server."
        case let .serverNewer(current, appSupports):
            return "This server (v\(current)) is newer than this app understands (built for v\(appSupports)). Consider updating the app."
        }
    }
}
