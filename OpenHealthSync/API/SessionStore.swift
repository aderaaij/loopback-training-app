//
//  SessionStore.swift
//  OpenHealthSync
//
//  Owns the authenticated session: the bearer token (Keychain), the signed-in
//  user's display info (UserDefaults), and the derived `isAuthenticated` flag
//  the app root branches on. All credential changes flow through here so the
//  live API clients stay in sync.
//

import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    private(set) var isAuthenticated = false
    private(set) var serverURL = ""
    private(set) var username = ""
    private(set) var displayName = ""
    private(set) var role = ""

    /// The version reported by the server's `/api/health` on the last setup /
    /// login handshake; nil for a legacy server without the endpoint.
    private(set) var serverVersion: ServerVersion?
    /// How that version compares to what this app build supports. Purely
    /// advisory — a warning never blocks sign-in.
    private(set) var serverCompatibility: ServerCompatibility = .unknown

    private let apiClient: WorkoutAPIClient
    private weak var workoutManager: WorkoutManager?

    // MARK: Storage keys

    static let tokenKey = "trainingAPIToken"          // Keychain
    static let baseURLKey = "trainingAPIBaseURL"      // UserDefaults
    static let alternativeURLKey = "trainingAPIAlternativeURL" // UserDefaults
    static let tokenIdKey = "trainingAPITokenId"      // UserDefaults
    static let usernameKey = "trainingAPIUsername"    // UserDefaults
    static let displayNameKey = "trainingAPIDisplayName" // UserDefaults
    static let roleKey = "trainingAPIRole"            // UserDefaults
    static let serverVersionKey = "trainingAPIServerVersion" // UserDefaults (last /api/health version)
    static let legacyKeyKey = "trainingAPIKey"        // legacy UserDefaults API key
    static let onboardedKey = "hasCompletedOnboarding" // UserDefaults (@AppStorage in app root)

    init(apiClient: WorkoutAPIClient, workoutManager: WorkoutManager) {
        self.apiClient = apiClient
        self.workoutManager = workoutManager

        let creds = Self.resolveCredentials()
        let defaults = UserDefaults.standard
        serverURL = creds.serverURL
        username = defaults.string(forKey: Self.usernameKey) ?? ""
        displayName = defaults.string(forKey: Self.displayNameKey) ?? ""
        role = defaults.string(forKey: Self.roleKey) ?? ""
        serverVersion = defaults.string(forKey: Self.serverVersionKey).flatMap(ServerVersion.init)
        serverCompatibility = ServerCompatibility.evaluate(serverVersion)
        isAuthenticated = !creds.token.isEmpty && !creds.serverURL.isEmpty

        // A session restored from the Keychain means this account already used
        // the app (e.g. a reinstall wiped UserDefaults but not the Keychain) —
        // never re-run first-athlete onboarding for it.
        if isAuthenticated {
            defaults.set(true, forKey: Self.onboardedKey)
        }
    }

    /// Whether we have a saved display name to show ("Signed in as …").
    var accountLabel: String {
        if !displayName.isEmpty { return displayName }
        if !username.isEmpty { return username }
        return "your account"
    }

    // MARK: - Sign in

    /// Server-version handshake before adopting a URL (doc §1–2). Confirms the
    /// address is a healthy Loopback server — throwing `.notLoopbackServer` /
    /// `.databaseUnavailable` when it isn't — and records the reported version.
    /// A transport failure rethrows: the follow-up sign-in would only time out
    /// against the same dead address, so surface it now. A server that answers
    /// without a health payload (pre-0.1.0, non-JSON) degrades to `.unknown`
    /// so the caller can still try to sign in. Returns the compatibility
    /// verdict; a warning is advisory, never fatal.
    @discardableResult
    func probeServerHealth(serverURL rawURL: String) async throws -> ServerCompatibility {
        let url = Self.normalizedURL(rawURL)
        let health: ServerHealth
        do {
            health = try await apiClient.fetchHealth(on: url)
        } catch let error as URLError {
            // Unreachable — nothing was learned about the server, so the last
            // known version stays.
            throw error
        } catch {
            // The server answered, but not with a health payload (pre-0.1.0
            // server or a non-JSON response). Don't block on it — clear the
            // stale version and sign in without one.
            storeServerVersion(nil)
            return .unknown
        }
        guard health.isLoopbackServer else {
            throw WorkoutAPIError.notLoopbackServer(service: health.service)
        }
        guard health.databaseOK else {
            throw WorkoutAPIError.databaseUnavailable
        }
        storeServerVersion(health.semanticVersion)
        return serverCompatibility
    }

    /// Silent version refresh for an established session (Settings → Account),
    /// so the displayed version doesn't go stale on a server upgraded since
    /// login. Uses the configured route — failover included — and records only
    /// a successful Loopback answer; any failure keeps the last known version.
    func refreshServerHealth() async {
        guard isAuthenticated else { return }
        guard let health = try? await apiClient.fetchHealth(),
              health.isLoopbackServer else { return }
        storeServerVersion(health.semanticVersion)
    }

    func login(serverURL rawURL: String, username: String, password: String, deviceName: String) async throws {
        let url = Self.normalizedURL(rawURL)
        let response = try await apiClient.login(
            baseURL: url,
            username: username,
            password: password,
            deviceName: deviceName
        )
        await establish(
            serverURL: url.absoluteString,
            token: response.token,
            tokenId: response.tokenId,
            user: response.user
        )
    }

    /// Advanced path: apply a pasted token directly (same Bearer credential as a
    /// logged-in token). Verifies it before persisting; best-effort fetches the
    /// user for display.
    func applyManualToken(serverURL rawURL: String, token: String) async throws {
        let url = Self.normalizedURL(rawURL)

        // Handshake first: reject a non-Loopback or DB-down address before
        // adopting the token, and record the server version. A warning here is
        // advisory (this path has no "anyway" step), so the verdict is ignored.
        _ = try await probeServerHealth(serverURL: rawURL)

        await configureClients(serverURL: url.absoluteString, token: token)

        // Throws on an unreachable host or a bad token (401) without posting the
        // global unauthorized signal, so a failed attempt won't sign the user out.
        try await apiClient.checkConnection()

        let user = (try? await apiClient.fetchMe())?.user
        await establish(serverURL: url.absoluteString, token: token, tokenId: nil, user: user)
    }

    // MARK: - Sign out

    /// Best-effort server-side revoke, then always clear local credentials.
    func signOut() async {
        if let tokenId = UserDefaults.standard.string(forKey: Self.tokenIdKey) {
            try? await apiClient.revokeToken(id: tokenId)
        }
        clearSession()
    }

    /// Called when any authenticated request returns 401. Clears the token and
    /// drops to the login screen; server URL + username are kept to prefill it.
    func handleUnauthorized() {
        guard isAuthenticated else { return }
        clearSession()
    }

    // MARK: - Internals

    /// Records the server version (published + persisted) and re-derives the
    /// compatibility verdict from it. Passing nil clears both.
    private func storeServerVersion(_ version: ServerVersion?) {
        serverVersion = version
        serverCompatibility = ServerCompatibility.evaluate(version)
        let defaults = UserDefaults.standard
        if let version {
            defaults.set(version.description, forKey: Self.serverVersionKey)
        } else {
            defaults.removeObject(forKey: Self.serverVersionKey)
        }
    }

    private func establish(serverURL: String, token: String, tokenId: String?, user: AuthUser?) async {
        // A different server or account invalidates cached responses from the
        // previous one — clear before any fetch below can warm the cache.
        let defaultsBefore = UserDefaults.standard
        let previousURL = defaultsBefore.string(forKey: Self.baseURLKey)
        let previousUsername = defaultsBefore.string(forKey: Self.usernameKey)
        if previousURL != serverURL || (user != nil && previousUsername != user?.username) {
            await apiClient.clearCache()
        }

        await configureClients(serverURL: serverURL, token: token)

        Keychain.set(token, for: Self.tokenKey)
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: Self.baseURLKey)
        if let tokenId {
            defaults.set(tokenId, forKey: Self.tokenIdKey)
        } else {
            defaults.removeObject(forKey: Self.tokenIdKey)
        }
        if let user {
            defaults.set(user.username, forKey: Self.usernameKey)
            defaults.set(user.displayName, forKey: Self.displayNameKey)
            defaults.set(user.role, forKey: Self.roleKey)
            username = user.username
            displayName = user.displayName
            role = user.role
        }

        // An account that already has training plans is established — skip the
        // first-athlete onboarding for it. Decided before `isAuthenticated`
        // flips so the app root never flashes the onboarding branch. Best
        // effort: on failure the flag stays false and onboarding (skippable)
        // shows.
        if !defaults.bool(forKey: Self.onboardedKey),
           let plans = try? await apiClient.fetchAllPlans(), !plans.isEmpty {
            defaults.set(true, forKey: Self.onboardedKey)
        }

        self.serverURL = serverURL
        isAuthenticated = true
    }

    private func clearSession() {
        // Cached responses belong to the session that just ended.
        let apiClient = self.apiClient
        Task { await apiClient.clearCache() }

        // The status dot should not keep reporting on a connection that no
        // longer exists.
        ServerStatusMonitor.shared.reset()

        Keychain.delete(Self.tokenKey)
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.tokenIdKey)
        defaults.removeObject(forKey: Self.legacyKeyKey)
        // Reset onboarding so a different account signing in on this device is
        // evaluated fresh (an established account re-skips it via the plan
        // check on login).
        defaults.removeObject(forKey: Self.onboardedKey)
        // Keep serverURL + username to prefill the login form on the way back in.
        displayName = ""
        role = ""
        isAuthenticated = false
    }

    private func configureClients(serverURL: String, token: String) async {
        let url = URL(string: serverURL) ?? URL(string: "https://localhost")!
        let alternative = Self.storedAlternativeURL
        await apiClient.configure(baseURL: url, alternativeURL: alternative, apiKey: token)
        workoutManager?.configure(
            serverURL: serverURL,
            alternativeURL: alternative?.absoluteString,
            apiKey: token
        )
    }

    /// Re-pushes the current configuration after the Settings fallback-URL
    /// field changes, so the new route applies without a sign-out.
    func applyAlternativeURL() async {
        guard isAuthenticated else { return }
        let creds = Self.resolveCredentials()
        await configureClients(serverURL: creds.serverURL, token: creds.token)
    }

    /// The optional fallback URL, normalized; nil when unset. The Settings
    /// field stores the raw text as typed (so editing round-trips), which is
    /// why normalization happens here at read time.
    static var storedAlternativeURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: alternativeURLKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalizedURL(trimmed)
    }

    // MARK: - Credential resolution (also runs one-time migration)

    /// Reads the current server URL + token, migrating a legacy pasted API key
    /// into the Keychain the first time. Safe to call repeatedly. Used by both
    /// the app init (to configure the client synchronously) and this store (to
    /// seed published state).
    static func resolveCredentials() -> (serverURL: String, token: String) {
        let defaults = UserDefaults.standard
        let serverURL = defaults.string(forKey: baseURLKey) ?? ""

        if Keychain.get(tokenKey) == nil,
           let legacy = defaults.string(forKey: legacyKeyKey), !legacy.isEmpty {
            // Migrate the previously pasted API key into the Keychain (doc §8).
            Keychain.set(legacy, for: tokenKey)
            defaults.removeObject(forKey: legacyKeyKey)
        }

        return (serverURL, Keychain.get(tokenKey) ?? "")
    }

    static func normalizedURL(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            ? trimmed
            : "https://\(trimmed)"
        return URL(string: withScheme) ?? URL(string: "https://localhost")!
    }
}
