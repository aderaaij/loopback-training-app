//
//  WorkoutAPIClient.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 14/03/2026.
//

import Foundation
import Network
import os
import Synchronization
#if DEBUG
import Pulse
#endif

actor WorkoutAPIClient {
    private var baseURL: URL
    private var alternativeURL: URL?
    private var apiKey: String

    // Which of primary/alternative the last successful request used. Shared
    // across client instances — the upload client and the main client talk to
    // the same server, so a working route found by one redirects the other.
    private nonisolated static let prefersAlternative = Mutex(false)

    // A network-path change (Wi-Fi ↔ cellular, VPN up or down) makes the
    // primary URL worth trying again; the next request re-discovers the
    // working route, failing over again if the primary is still down.
    private nonisolated static let pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            WorkoutAPIClient.prefersAlternative.withLock { $0 = false }
        }
        monitor.start(queue: DispatchQueue(label: "server-path-monitor"))
        return monitor
    }()

    // Debug builds record every request with Pulse for on-device inspection
    // (Settings → Network Log). This must be Pulse's URLSessionProxy, not a
    // URLSession with a proxy delegate: the async data(for:) API routes
    // per-task events past session-level delegates, which leaves every
    // request stuck "pending" in the console. The Authorization header is
    // redacted before anything reaches the log store.
    #if DEBUG
    private nonisolated static let session: URLSessionProxy = {
        var loggerConfiguration = NetworkLogger.Configuration()
        loggerConfiguration.sensitiveHeaders = ["Authorization"]
        var options = URLSessionProxy.Options()
        options.isMockingEnabled = false
        return URLSessionProxy(
            configuration: .default,
            logger: NetworkLogger(configuration: loggerConfiguration),
            options: options
        )
    }()
    #else
    private nonisolated static let session = URLSession.shared
    #endif

    // Identifies the app to the server on every request. The dashboard records
    // this per-token (`last_user_agent`) and pretty-prints the `Loopback-iOS/`
    // prefix specifically, so the format is exact on purpose.
    private nonisolated static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "Loopback-iOS/\(version)"
    }()

    var isConfigured: Bool { true }

    // The API speaks ISO-8601 dates in both directions; every endpoint goes
    // through these shared coders so no method can drift to a different
    // date strategy.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(baseURL: String? = nil, alternativeURL: String? = nil, apiKey: String? = nil) {
        self.baseURL = URL(string: baseURL ?? "") ?? URL(string: "https://localhost")!
        self.alternativeURL = alternativeURL.flatMap { URL(string: $0) }
        self.apiKey = apiKey ?? ""
        _ = Self.pathMonitor // start route re-discovery on path changes
    }

    func configure(baseURL: URL, alternativeURL: URL?, apiKey: String) {
        self.baseURL = baseURL
        self.alternativeURL = alternativeURL
        self.apiKey = apiKey
    }

    // MARK: - Request Engine

    /// Builds, sends, and validates every request. A 401 posts
    /// `.trainingAPIUnauthorized` (dead session → app routes to login) unless
    /// `signalsUnauthorized` is false — endpoints that probe candidate
    /// credentials or run during sign-out must surface auth failures locally
    /// instead of wiping the current session.
    ///
    /// Status codes in `accepting` are returned as success so callers can
    /// branch on them (404 → nil, 409 → idempotent create, ...).
    @discardableResult
    private func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accepting extraOK: Set<Int> = [],
        signalsUnauthorized: Bool = true,
        timeout: TimeInterval? = nil,
        on overrideURL: URL? = nil,
        authenticated: Bool = true
    ) async throws -> (data: Data, status: Int) {
        let (data, status, _) = try await performReachingBase(
            method, path,
            query: query,
            body: body,
            accepting: extraOK,
            signalsUnauthorized: signalsUnauthorized,
            timeout: timeout,
            on: overrideURL,
            authenticated: authenticated
        )
        return (data, status)
    }

    /// `baseURL` in the result is the base the request effectively reached;
    /// see `redirect(requested:path:response:)` for why that can differ from
    /// the one passed in.
    ///
    /// A 401 that comes back from another address than the one asked is not
    /// a dead session either: it throws `.redirected` and leaves the session
    /// alone, whatever `signalsUnauthorized` says.
    @discardableResult
    private func performReachingBase(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accepting extraOK: Set<Int> = [],
        signalsUnauthorized: Bool = true,
        timeout: TimeInterval? = nil,
        on overrideURL: URL? = nil,
        authenticated: Bool = true
    ) async throws -> (data: Data, status: Int, baseURL: URL) {
        func makeRequest(on base: URL) -> URLRequest {
            var url = base.appendingPathComponent(path)
            if !query.isEmpty {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.queryItems = query
                url = components.url!
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            if authenticated {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            if let timeout {
                request.timeoutInterval = timeout
            }
            return request
        }

        // Route selection: an explicit override (login probing a candidate
        // URL) never fails over; otherwise start from whichever of
        // primary/alternative last worked and keep the other as the one-shot
        // retry candidate.
        let first: URL
        var second: URL?
        var usedAlternative = false
        if let overrideURL {
            first = overrideURL
        } else if let alternativeURL, Self.prefersAlternative.withLock({ $0 }) {
            first = alternativeURL
            second = baseURL
            usedAlternative = true
        } else {
            first = baseURL
            second = alternativeURL
        }
        var usedBase = first

        var data: Data
        var response: URLResponse
        do {
            do {
                (data, response) = try await Self.session.data(for: makeRequest(on: first))
            } catch let error where second != nil && Self.shouldFailover(on: error) {
                let fallback = second!
                AppLog.sync.warning("Request to \(first.absoluteString, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); retrying on \(fallback.absoluteString, privacy: .public)")
                (data, response) = try await Self.session.data(for: makeRequest(on: fallback))
                usedBase = fallback
                usedAlternative.toggle()
                Self.prefersAlternative.withLock { $0 = usedAlternative }
                AppLog.sync.info("Failover succeeded; preferring \(fallback.absoluteString, privacy: .public) until the network path changes")
            }
        } catch {
            Self.reportStatus(.connectionError)
            throw error
        }

        guard var http = response as? HTTPURLResponse else {
            Self.reportStatus(.connectionError)
            throw WorkoutAPIError.invalidResponse
        }

        // URLSession follows redirects but drops `Authorization` when one
        // leaves the origin, so what comes back from the far side says
        // nothing about the session.
        var redirect = Self.redirect(requested: usedBase, path: path, response: http)

        // A configured http:// address that the same host now answers over
        // https (the fallback URL, or a proxy that started redirecting after
        // sign-in): use the https address from here on, and send this request
        // again with its header unless it got through anyway.
        if overrideURL == nil, case .upgraded(let secureBase) = redirect {
            AppLog.sync.info("\(usedBase.absoluteString, privacy: .public) redirects to https; using \(secureBase.absoluteString, privacy: .public) from now on")
            adopt(secureBase, inPlaceOf: usedBase)
            usedBase = secureBase
            redirect = .none
            if authenticated, !(200...299).contains(http.statusCode) {
                do {
                    (data, response) = try await Self.session.data(for: makeRequest(on: secureBase))
                } catch {
                    Self.reportStatus(.connectionError)
                    throw error
                }
                guard let retried = response as? HTTPURLResponse else {
                    Self.reportStatus(.connectionError)
                    throw WorkoutAPIError.invalidResponse
                }
                http = retried
                redirect = Self.redirect(requested: secureBase, path: path, response: http)
            }
        }

        let code = http.statusCode
        if case .elsewhere(let origin, let matchingBase) = redirect {
            // Signing in: an address that hands off to another host is
            // refused before a password or token goes to it. Only when the
            // redirect kept the path is there an address to suggest; a jump
            // to some other page (a proxy's login wall) falls through to the
            // usual errors.
            if overrideURL != nil {
                if let matchingBase { throw WorkoutAPIError.redirected(to: matchingBase) }
            } else {
                // Signed in: the route is what is wrong, whatever this one
                // request got. The health check needs no header and succeeds
                // over there, which must not read as "Connected".
                let target = matchingBase ?? origin
                Self.reportStatus(.redirected(to: Self.displayString(target)), viaFallback: usedAlternative)
                // A 401 is the far side missing the dropped header, not a
                // dead session. Signing out would not help, and the same
                // address would end the next session the same way.
                if code == 401, authenticated {
                    throw WorkoutAPIError.redirected(to: target)
                }
                if (200...299).contains(code) || extraOK.contains(code) {
                    return (data, code, usedBase)
                }
                throw WorkoutAPIError.serverError(code)
            }
        }

        // Any HTTP response proves the server is reachable; only a genuine
        // dead session (not a candidate-credential probe) downgrades to
        // authenticationError.
        Self.reportStatus(
            code == 401 && signalsUnauthorized ? .authenticationError : .connected,
            viaFallback: usedAlternative
        )
        if (200...299).contains(code) || extraOK.contains(code) {
            if case .upgraded(let secureBase) = redirect {
                return (data, code, secureBase)
            }
            return (data, code, usedBase)
        }
        if code == 401, signalsUnauthorized {
            NotificationCenter.default.post(name: .trainingAPIUnauthorized, object: nil)
            throw WorkoutAPIError.unauthorized
        }
        throw WorkoutAPIError.serverError(code)
    }

    /// Replaces a configured address with the https one its host redirects
    /// to, and tells the session so the change is stored and reaches the
    /// other client.
    private func adopt(_ secureBase: URL, inPlaceOf old: URL) {
        if baseURL == old { baseURL = secureBase }
        if alternativeURL == old { alternativeURL = secureBase }
        NotificationCenter.default.post(
            name: .trainingAPIServerURLUpgraded,
            object: nil,
            userInfo: [ServerURLUpgrade.fromKey: old, ServerURLUpgrade.toKey: secureBase]
        )
    }

    /// Transport failures that can plausibly be route-specific — a hostname
    /// that only resolves on one network, a VPN that's down — and therefore
    /// worth one retry on the other URL. Anything else fails as usual.
    private nonisolated static func shouldFailover(on error: Error) -> Bool {
        switch (error as? URLError)?.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Where the answer to a request came from, compared with the base it
    /// was sent to.
    private enum Redirect {
        /// From the origin that was asked (redirects within it included).
        case none
        /// From the same host over https, after asking over http. Carries the
        /// base rebuilt as https: its host and path prefix, with the scheme
        /// and port coming from the redirect.
        case upgraded(URL)
        /// From another host, or over another scheme or port that is not
        /// that upgrade. `matchingBase` is the base to use over there when
        /// the redirect kept the request's path, nil when it led to some
        /// other page.
        case elsewhere(origin: URL, matchingBase: URL?)
    }

    /// A reverse proxy answers an http:// base with a redirect to https
    /// (POST /api/auth/login → 308, GETs → 301), and some send a bare domain
    /// on to `www.`. URLSession follows both but drops `Authorization` on the
    /// way, so authenticated requests arrive with no token and get a 401.
    /// The same-host http→https case is safe to adopt as the new base; any
    /// other change of origin is for the athlete to confirm by entering it.
    private nonisolated static func redirect(requested base: URL, path: String, response: HTTPURLResponse) -> Redirect {
        guard let finalURL = response.url,
              let finalHost = finalURL.host, let baseHost = base.host,
              let finalScheme = finalURL.scheme?.lowercased(),
              let baseScheme = base.scheme?.lowercased() else {
            return .none
        }
        func port(_ url: URL, _ scheme: String) -> Int {
            url.port ?? (scheme == "https" ? 443 : 80)
        }
        let sameHost = finalHost.caseInsensitiveCompare(baseHost) == .orderedSame
        if sameHost, finalScheme == baseScheme, port(finalURL, finalScheme) == port(base, baseScheme) {
            return .none
        }
        if sameHost, baseScheme == "http", finalScheme == "https",
           var components = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            components.port = finalURL.port
            if let secureBase = components.url { return .upgraded(secureBase) }
        }

        guard var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false) else {
            return .none
        }
        components.query = nil
        components.fragment = nil
        var matchingBase: URL?
        let suffix = "/" + path
        if components.path.hasSuffix(suffix) {
            components.path.removeLast(suffix.count)
            matchingBase = components.url
        }
        components.path = ""
        guard let origin = components.url else { return .none }
        return .elsewhere(origin: origin, matchingBase: matchingBase)
    }

    /// An address the way the athlete would type it: no trailing slash.
    nonisolated static func displayString(_ url: URL) -> String {
        let text = url.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// Fire-and-forget hop to the main actor so publishing never delays a request.
    private nonisolated static func reportStatus(_ status: ServerStatus, viaFallback: Bool = false) {
        Task { @MainActor in
            ServerStatusMonitor.shared.record(status, viaFallback: viaFallback)
        }
    }

    /// `perform` + decode with the shared ISO-8601 decoder. When `cacheKey` is
    /// set, the raw bytes of a successfully-decoded response are stored so the
    /// matching `cached…()` accessor can replay them on the next launch.
    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        signalsUnauthorized: Bool = true,
        cacheKey: String? = nil
    ) async throws -> T {
        let (data, _) = try await perform(
            method, path,
            query: query,
            body: body,
            signalsUnauthorized: signalsUnauthorized
        )
        let value = try Self.decoder.decode(T.self, from: data)
        if let cacheKey {
            storeCached(data, for: cacheKey)
        }
        return value
    }

    // MARK: - Response Cache (offline-first rendering)
    //
    // Stores the raw bytes of the last successful response for selected GET
    // endpoints so screens can render instantly (and offline) before the
    // network refresh lands. Cached bytes go through the same shared decoder,
    // so a cache read behaves exactly like the original response.

    private enum CacheKey {
        static let activePlans = "plans-active"
        static let allPlans = "plans-all"
        static let scheduleCalendar = "schedule-calendar"
        static let workoutPlanLinks = "workout-plan-links"
        static func planWorkouts(_ planId: UUID) -> String { "plan-workouts-\(planId.uuidString)" }
    }

    private nonisolated static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("APIResponseCache", isDirectory: true)
    }

    private func storeCached(_ data: Data, for key: String) {
        let directory = Self.cacheDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
    }

    private func cached<T: Decodable>(_ key: String) -> T? {
        guard let data = try? Data(contentsOf: Self.cacheDirectory.appendingPathComponent("\(key).json")) else {
            return nil
        }
        return try? Self.decoder.decode(T.self, from: data)
    }

    /// Wipes every cached response. Called when the session ends or the
    /// account/server changes, so one account never renders another's data.
    func clearCache() {
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    func cachedActivePlans() -> [TrainingPlan]? { cachedPlans(for: CacheKey.activePlans) }
    func cachedAllPlans() -> [TrainingPlan]? { cachedPlans(for: CacheKey.allPlans) }
    func cachedScheduleCalendar() -> CalendarResponse? { cached(CacheKey.scheduleCalendar) }
    func cachedWorkoutPlanLinks() -> [WorkoutPlanLink]? { cached(CacheKey.workoutPlanLinks) }
    func cachedPlanWorkouts(planId: UUID) -> [PlanWorkout]? { cached(CacheKey.planWorkouts(planId)) }

    private func cachedPlans(for key: String) -> [TrainingPlan]? {
        let wrapped: [FailableDecodable<TrainingPlan>]? = cached(key)
        return wrapped.map { $0.compactMap(\.value) }
    }

    /// Performs a lightweight authenticated request to verify the current
    /// base URL and API key. Throws on an unreachable host or a non-2xx
    /// (e.g. 401 for a bad key) so callers can surface a connection result.
    /// Does not signal unauthorized: this verifies a candidate credential
    /// (e.g. a pasted token in Settings) and a 401 here must surface as an
    /// error, not sign the current session out.
    func checkConnection() async throws {
        try await perform("GET", "api/plans", signalsUnauthorized: false, timeout: 15)
    }

    // MARK: - Authentication

    /// Server-version handshake: `GET /api/health`, unauthenticated so it runs
    /// before login. `on:` targets the candidate URL being set up (no failover
    /// to the configured route). Any non-2xx throws — a server without the
    /// endpoint (pre-0.1.0) surfaces as an error the setup flow degrades on.
    /// Returns the health payload plus the base URL the probe effectively
    /// reached (https when the proxy redirected http→https).
    func fetchHealth(on baseURL: URL? = nil) async throws -> (health: ServerHealth, baseURL: URL) {
        let (data, _, effectiveBase) = try await performReachingBase(
            "GET", "api/health",
            signalsUnauthorized: false,
            timeout: 15,
            on: baseURL,
            authenticated: false
        )
        return (try Self.decoder.decode(ServerHealth.self, from: data), effectiveBase)
    }

    /// Exchanges username + password for a bearer token. Unauthenticated by
    /// design; maps auth-specific status codes to typed errors so the login
    /// UI can message them (a 401 here is a bad password, not a dead session).
    /// Returns the token response plus the base URL login effectively reached
    /// (https when the proxy redirected http→https), so the caller can persist
    /// the upgraded URL.
    func login(baseURL: URL, username: String, password: String, deviceName: String) async throws -> (response: LoginResponse, baseURL: URL) {
        let body = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
            "deviceName": deviceName,
        ])

        let (data, status, effectiveBase) = try await performReachingBase(
            "POST", "api/auth/login",
            body: body,
            accepting: [401, 429],
            timeout: 20,
            on: baseURL,
            authenticated: false
        )

        switch status {
        case 401: throw WorkoutAPIError.invalidCredentials
        case 429: throw WorkoutAPIError.rateLimited
        default: return (try Self.decoder.decode(LoginResponse.self, from: data), effectiveBase)
        }
    }

    /// Current user + their tokens. Used to populate "Signed in as …".
    /// Doesn't signal unauthorized: called while applying a candidate manual
    /// token, before the session is established.
    func fetchMe() async throws -> MeResponse {
        try await request("GET", "api/auth/me", signalsUnauthorized: false)
    }

    /// Revokes a token by id (logout / sign out a device). 204 = revoked,
    /// 404 = already gone — both treated as success. Doesn't signal
    /// unauthorized: runs during sign-out, when the session is being cleared
    /// anyway.
    func revokeToken(id: String) async throws {
        try await perform("DELETE", "api/auth/tokens/\(id)", accepting: [404], signalsUnauthorized: false)
    }

    // MARK: - Workout Upload

    /// Uploads a workout and returns it as the server stored it, or nil when
    /// the response can't be read. The stored plan link can differ from the
    /// one sent: a link the athlete set by hand outlives a re-upload.
    @discardableResult
    func send(data: Data) async throws -> WorkoutPlanLink? {
        let (response, _) = try await perform("POST", "api/workouts", body: data)
        return try? Self.decoder.decode(WorkoutPlanLink.self, from: response)
    }

    // MARK: - Workout History (server-side aggregates & linkage)

    /// Per-period aggregates over the full server-side workout history,
    /// newest period first. Volume is tiny (one row per period per activity),
    /// so there's no pagination. Periods with no workouts are simply absent —
    /// callers fill gaps when charting.
    func fetchWorkoutSummary(period: String, activityType: String? = nil) async throws -> [ServerWorkoutSummaryRow] {
        var query = [URLQueryItem(name: "period", value: period)]
        if let activityType {
            query.append(URLQueryItem(name: "activity_type", value: activityType))
        }
        return try await request("GET", "api/workouts/summary", query: query)
    }

    /// Authoritative plan linkage for a synced workout (queue item, plan,
    /// feedback). `id` is the HealthKit UUID — the server's workout PK.
    /// A 404 means the workout isn't on the server (not synced yet, or a
    /// different account) — that's a normal case and returns nil; only a 401
    /// goes through the session-wipe path.
    func fetchWorkoutContext(id: UUID) async throws -> WorkoutContext? {
        let (data, status) = try await perform("GET", "api/workouts/\(id.uuidString)/context", accepting: [404])
        if status == 404 { return nil }
        return try Self.decoder.decode(WorkoutContext.self, from: data)
    }

    // MARK: - Plan Links

    /// Which planned session each recent workout counts for, newest first.
    /// Read from the workout list, which carries no samples, so it is small.
    func fetchWorkoutPlanLinks() async throws -> [WorkoutPlanLink] {
        try await request(
            "GET", "api/workouts",
            query: [URLQueryItem(name: "limit", value: "200")],
            cacheKey: CacheKey.workoutPlanLinks
        )
    }

    /// Counts a workout for a planned session; nil unlinks it. Returns the
    /// workout's new context. Needs server 0.1.20 or later: an older one
    /// answers 404 or 405.
    func setWorkoutPlanLink(workoutId: UUID, planWorkoutId: UUID?) async throws -> WorkoutContext {
        let value: Any = planWorkoutId?.uuidString ?? NSNull()
        return try await request(
            "PUT", "api/workouts/\(workoutId.uuidString)/plan-link",
            body: JSONSerialization.data(withJSONObject: ["planWorkoutId": value])
        )
    }

    // MARK: - Shoes (server 0.1.19+)

    func fetchShoes() async throws -> [Shoe] {
        try await request("GET", "api/shoes")
    }

    func createShoe(_ draft: ShoeDraft) async throws -> Shoe {
        try await request("POST", "api/shoes", body: Self.shoeBody(draft))
    }

    /// Replaces everything the athlete can edit on a pair.
    func updateShoe(id: UUID, draft: ShoeDraft) async throws -> Shoe {
        try await request("PATCH", "api/shoes/\(id.uuidString)", body: Self.shoeBody(draft))
    }

    /// Retires a pair or brings it back. Retiring also clears "default".
    func updateShoe(id: UUID, retired: Bool) async throws -> Shoe {
        try await request(
            "PATCH", "api/shoes/\(id.uuidString)",
            body: JSONSerialization.data(withJSONObject: ["retired": retired])
        )
    }

    func deleteShoe(id: UUID) async throws {
        try await perform("DELETE", "api/shoes/\(id.uuidString)")
    }

    /// The pair on a workout. Read from the workout without its samples; a
    /// 404 (workout not on the server) returns nil.
    func fetchWorkoutShoe(workoutId: UUID) async throws -> WorkoutShoe? {
        let (data, status) = try await perform(
            "GET", "api/workouts/\(workoutId.uuidString)",
            query: [URLQueryItem(name: "include_samples", value: "false")],
            accepting: [404]
        )
        if status == 404 { return nil }
        return try Self.decoder.decode(WorkoutShoe.self, from: data)
    }

    /// Runs started since `date`, each with its pair and whether it was checked.
    func fetchRunShoeStates(since date: Date) async throws -> [RunShoeState] {
        try await request(
            "GET", "api/workouts",
            query: [
                URLQueryItem(name: "activity_type", value: "running"),
                URLQueryItem(name: "start_after", value: ISO8601DateFormatter().string(from: date)),
                URLQueryItem(name: "limit", value: "100"),
            ]
        )
    }

    /// Puts a pair on a workout; nil takes it off. Either way the server
    /// counts the workout's pair as checked from then on.
    func setWorkoutShoe(workoutId: UUID, shoeId: UUID?) async throws {
        let value: Any = shoeId?.uuidString ?? NSNull()
        try await perform(
            "PUT", "api/workouts/\(workoutId.uuidString)/shoe",
            body: JSONSerialization.data(withJSONObject: ["shoeId": value])
        )
    }

    /// A missing target has to go out as an explicit null, which Codable's
    /// synthesized encoding would drop.
    private static func shoeBody(_ draft: ShoeDraft) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "name": draft.name,
            "startDistance": draft.startDistance,
            "targetDistance": draft.targetDistance ?? NSNull(),
            "isDefault": draft.isDefault,
        ] as [String: Any])
    }

    // MARK: - Setbacks (server 0.1.25+)

    func fetchSetbacks() async throws -> [Setback] {
        try await request("GET", "api/setbacks")
    }

    /// `id` makes a retried create land on the same row.
    func createSetback(_ draft: SetbackDraft, id: UUID) async throws -> Setback {
        var body = Self.setbackFields(draft)
        body["id"] = id.uuidString
        return try await request("POST", "api/setbacks", body: JSONSerialization.data(withJSONObject: body))
    }

    /// Replaces everything the athlete can edit on a setback.
    func updateSetback(id: UUID, draft: SetbackDraft) async throws -> Setback {
        try await request(
            "PATCH", "api/setbacks/\(id.uuidString)",
            body: JSONSerialization.data(withJSONObject: Self.setbackFields(draft))
        )
    }

    /// Closes a setback on its last day, or reopens it with nil.
    func setSetbackEnd(id: UUID, end: SetbackDay?) async throws -> Setback {
        let value: Any = end?.text ?? NSNull()
        return try await request(
            "PATCH", "api/setbacks/\(id.uuidString)",
            body: JSONSerialization.data(withJSONObject: ["endDate": value])
        )
    }

    func deleteSetback(id: UUID) async throws {
        try await perform("DELETE", "api/setbacks/\(id.uuidString)")
    }

    /// How the athlete felt on one day; sending a day again replaces it.
    func putSetbackCheckin(id: UUID, day: SetbackDay, status: SetbackStatus) async throws -> Setback {
        try await request(
            "PUT", "api/setbacks/\(id.uuidString)/checkins/\(day.text)",
            body: JSONSerialization.data(withJSONObject: ["status": status.rawValue])
        )
    }

    /// Cleared fields go out as explicit nulls, which Codable's synthesized
    /// encoding would drop.
    private static func setbackFields(_ draft: SetbackDraft) -> [String: Any] {
        [
            "kind": draft.kind.rawValue,
            "severity": draft.severity.rawValue,
            "startDate": draft.start.text,
            "endDate": draft.end?.text ?? NSNull(),
            "bodyPart": draft.bodyPart ?? NSNull(),
            "note": draft.note ?? NSNull(),
        ]
    }

    // MARK: - Workout Inventory Sync

    func syncInventory(_ inventory: [WorkoutInventoryItem]) async throws {
        try await perform("PUT", "api/workouts/inventory", body: Self.encoder.encode(inventory))
    }

    // MARK: - Workout Queue

    func fetchQueue() async throws -> [QueuedWorkoutComposition] {
        try await request("GET", "api/workouts/queue")
    }

    /// Delivered workouts that are still due on or after `from` (server
    /// 0.1.14+): what the watch schedule should hold beyond the pending
    /// queue. `synced` is per account, not per device, so this is the only
    /// way a reinstall or a new phone gets those runs back. A server that
    /// predates the endpoint answers 404, which throws like any other error.
    func fetchScheduledQueue(from: Date) async throws -> [QueuedWorkoutComposition] {
        // ISO8601DateFormatter emits UTC with a "Z"; an offset's "+" would
        // reach the server as a space (URLComponents leaves "+" unescaped).
        let since = ISO8601DateFormatter().string(from: from)
        return try await request("GET", "api/workouts/queue/scheduled", query: [URLQueryItem(name: "from", value: since)])
    }

    func updateQueueItemStatus(id: UUID, status: String) async throws {
        try await perform(
            "PATCH", "api/workouts/queue/\(id.uuidString)",
            body: Self.encoder.encode(["status": status])
        )
    }

    func deleteQueueItem(id: UUID) async throws {
        try await perform("DELETE", "api/workouts/queue/\(id.uuidString)")
    }

    /// Marks a queued plan workout as completed, server stamps completed_at idempotently
    /// (only writes when currently null, so dual-write with inventory sync is safe).
    func markPlanWorkoutCompleted(id: UUID) async throws {
        try await perform(
            "PATCH", "api/queue/\(id.uuidString)/status",
            body: Self.encoder.encode(["status": "completed"])
        )
    }

    // MARK: - Pending Actions (edit/delete)

    func fetchPendingActions() async throws -> [PendingWorkoutAction] {
        try await request("GET", "api/workouts/actions")
    }

    func acknowledgePendingAction(id: UUID) async throws {
        try await perform("DELETE", "api/workouts/actions/\(id.uuidString)")
    }

    // MARK: - Workout Feedback

    /// 201 Created or 409 Conflict (idempotent re-submit) are both acceptable.
    ///
    /// A server older than 0.1.25 doesn't know the reasons "sick" and
    /// "injured" and answers 422. The check-in is then sent as "other" with
    /// the reason spelled out in the note, so it isn't retried forever.
    func submitFeedback(_ payload: WorkoutFeedbackPayload) async throws {
        let (_, status) = try await perform(
            "POST", "api/workouts/feedback",
            body: Self.encoder.encode(payload),
            accepting: [409, 422]
        )
        guard status == 422 else { return }
        guard let fallback = payload.forOlderServer else { throw WorkoutAPIError.serverError(422) }
        try await perform("POST", "api/workouts/feedback", body: Self.encoder.encode(fallback), accepting: [409])
    }

    // MARK: - Data Consent

    /// Tells the server which health domains the athlete shares, so the MCP
    /// layer can filter the tool list it advertises to the coach.
    ///
    /// Filtering the list matters more than refusing the calls. A tool that is
    /// advertised and then errors produces a coach that retries, apologises,
    /// and tells the athlete to go enable sleep tracking — reintroducing, in
    /// conversation, exactly the nagging the app's own surfaces were designed
    /// to avoid. An unadvertised tool simply isn't reasoned about.
    ///
    /// Older servers 404 here; the caller treats that as non-fatal, the same
    /// way nutrition tolerated a server that predated its endpoint.
    func sendDataConsent(_ payload: DataConsentPayload) async throws {
        try await perform("PUT", "api/me/data-consent", body: Self.encoder.encode(payload))
    }

    // MARK: - Display Units

    /// The units stored on the athlete's account, or nil when nobody has
    /// chosen yet. The dashboard and the coach read the same value.
    ///
    /// Throws on a server that predates the endpoint (its catch-all answers
    /// the GET with the dashboard's HTML, which doesn't decode); callers treat
    /// that as "keep the local choice".
    func fetchUnits() async throws -> DisplayUnits? {
        let (data, _) = try await perform("GET", "api/me/units")
        return try Self.decoder.decode(UnitsPayload.self, from: data).units.flatMap(DisplayUnits.init(rawValue:))
    }

    func sendUnits(_ units: DisplayUnits) async throws {
        try await perform("PUT", "api/me/units", body: Self.encoder.encode(UnitsPayload(units: units.rawValue)))
    }

    // MARK: - Health Metrics

    func sendHealthMetrics(_ payload: HealthMetricsBulkPayload) async throws {
        try await perform("POST", "api/health/metrics", body: Self.encoder.encode(payload))
    }

    /// Ships raw sleep samples. The server dedupes (`ON CONFLICT DO NOTHING`)
    /// and re-derives the affected nights' rollups, so re-sending the same
    /// samples is always safe.
    @discardableResult
    func sendSleepSamples(_ payload: SleepSamplesUploadPayload) async throws -> SleepSamplesUploadResponse {
        let (data, _) = try await perform("POST", "api/health/sleep/samples", body: Self.encoder.encode(payload))
        return try Self.decoder.decode(SleepSamplesUploadResponse.self, from: data)
    }

    // MARK: - Nutrition

    /// Bulk day upsert, same contract as `sendHealthMetrics`: null fields never
    /// overwrite stored values, and days with nothing logged are absent from
    /// the payload rather than zeroed.
    @discardableResult
    func sendNutrition(_ payload: NutritionBulkPayload) async throws -> HealthMetricsSyncResponse {
        let (data, _) = try await perform("POST", "api/nutrition", body: Self.encoder.encode(payload))
        return try Self.decoder.decode(HealthMetricsSyncResponse.self, from: data)
    }

    /// Daily nutrition rows for a date range, newest-agnostic (the Trends
    /// segment sorts them itself). Bounds are "yyyy-MM-dd". Unlogged days are
    /// simply absent from the response — that's "not tracked", not zero.
    func fetchNutrition(startDate: String, endDate: String? = nil, limit: Int? = nil) async throws -> [DailyNutrition] {
        var query = [URLQueryItem(name: "start_date", value: startDate)]
        if let endDate {
            query.append(URLQueryItem(name: "end_date", value: endDate))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let response: NutritionDaysResponse = try await request("GET", "api/nutrition", query: query)
        return response.days
    }

    // MARK: - Plan Notes (coach memory)

    /// Fetches existing notes for a conversation (used to dedupe onboarding
    /// re-runs). Query params are snake_case; response fields are camelCase.
    func fetchPlanNotes(conversationId: String, limit: Int = 50) async throws -> [PlanNote] {
        try await request("GET", "api/plan-notes", query: [
            URLQueryItem(name: "conversation_id", value: conversationId),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    /// Creates a new plan note (201 → the created note). Request body uses
    /// camelCase aliases (`conversationId`).
    @discardableResult
    func createPlanNote(_ note: PlanNoteCreate) async throws -> PlanNote {
        try await request("POST", "api/plan-notes", body: Self.encoder.encode(note))
    }

    /// Partial-updates an existing note by id (used to patch onboarding notes
    /// on re-run instead of creating duplicates).
    @discardableResult
    func updatePlanNote(id: String, _ update: PlanNoteUpdate) async throws -> PlanNote {
        try await request("PATCH", "api/plan-notes/\(id)", body: Self.encoder.encode(update))
    }

    // MARK: - Training Plans

    /// Fetches every active plan. A running plan and a strength cycle can be
    /// active simultaneously, so callers split the result by activity type.
    func fetchActivePlans() async throws -> [TrainingPlan] {
        try await fetchPlans(
            query: [URLQueryItem(name: "status", value: "active")],
            cacheKey: CacheKey.activePlans
        )
    }

    /// Fetches every plan (no status filter), newest first. Used by the plans
    /// browser to group plans into upcoming / current / archived.
    func fetchAllPlans() async throws -> [TrainingPlan] {
        try await fetchPlans(query: [], cacheKey: CacheKey.allPlans)
    }

    /// Decodes resiliently: a single plan with malformed (LLM-authored)
    /// metadata shouldn't blank the entire list.
    private func fetchPlans(query: [URLQueryItem], cacheKey: String) async throws -> [TrainingPlan] {
        let wrapped: [FailableDecodable<TrainingPlan>] = try await request(
            "GET", "api/plans",
            query: query,
            cacheKey: cacheKey
        )
        return wrapped.compactMap(\.value)
    }

    // MARK: - Plan Completion (celebration flow)

    /// Confirms a finishable plan as completed, optionally attaching a 1–5
    /// rating and free-text feedback. The server stores the feedback as a plan
    /// note the coach LLM reads when shaping the next block — nothing more to
    /// deliver from the app. A 400 means another surface (dashboard / coach)
    /// completed it first; that maps to `.planNotActive` so callers refresh
    /// instead of erroring.
    func completePlan(id: UUID, feedback: String?, rating: Int?) async throws -> PlanCompletionResponse {
        var body: [String: Any] = [:]
        if let feedback, !feedback.isEmpty { body["feedback"] = feedback }
        if let rating { body["rating"] = rating }

        let (data, status) = try await perform(
            "POST", "api/plans/\(id.uuidString)/complete",
            body: JSONSerialization.data(withJSONObject: body),
            accepting: [400]
        )
        if status == 400 { throw WorkoutAPIError.planNotActive }
        return try Self.decoder.decode(PlanCompletionResponse.self, from: data)
    }

    // MARK: - Unified Schedule Calendar (runs + strength)

    /// Fetches the merged run + strength agenda, date-sorted with conflict
    /// flags. Dates are "yyyy-MM-dd"; the server defaults to today..+28d
    /// when a bound is omitted.
    func fetchScheduleCalendar(from: String? = nil, to: String? = nil) async throws -> CalendarResponse {
        var query: [URLQueryItem] = []
        if let from { query.append(URLQueryItem(name: "from", value: from)) }
        if let to { query.append(URLQueryItem(name: "to", value: to)) }
        return try await request("GET", "api/schedule/calendar", query: query, cacheKey: CacheKey.scheduleCalendar)
    }

    /// Fetches a plan's cadence expanded to concrete dated sessions, with
    /// run-conflict warnings. Used by the strength plan detail screen.
    func fetchPlanSchedule(planId: UUID) async throws -> PlanScheduleResponse {
        try await request("GET", "api/plans/\(planId.uuidString)/schedule")
    }

    func fetchPlanWorkouts(planId: UUID) async throws -> [PlanWorkout] {
        try await request(
            "GET", "api/plans/\(planId.uuidString)/workouts",
            cacheKey: CacheKey.planWorkouts(planId)
        )
    }
}

extension Notification.Name {
    /// Posted by the API client when an authenticated request returns 401,
    /// signalling the session is no longer valid and the app should sign out.
    nonisolated static let trainingAPIUnauthorized = Notification.Name("trainingAPIUnauthorized")

    /// Posted by the API client when a configured http:// address turned out
    /// to be answered over https by the same host and the client switched to
    /// it. `userInfo` carries both addresses under the `ServerURLUpgrade`
    /// keys, so the session can store the new one.
    nonisolated static let trainingAPIServerURLUpgraded = Notification.Name("trainingAPIServerURLUpgraded")
}

nonisolated enum ServerURLUpgrade {
    static let fromKey = "from"
    static let toKey = "to"
}

enum WorkoutAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(Int)
    case unauthorized
    case invalidCredentials
    case rateLimited
    case planNotActive
    case notLoopbackServer(service: String)
    case databaseUnavailable
    /// The address hands requests off to another one, and the sign-in does
    /// not travel with them. Carries the address that answered.
    case redirected(to: URL)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Workout API client is not configured"
        case .invalidResponse:
            return "Invalid response from server"
        case .notLoopbackServer:
            return "That address isn't a Loopback server."
        case .databaseUnavailable:
            return "The server is reachable but its database is unavailable. Try again shortly."
        case .redirected(let target):
            return "This address redirects to \(WorkoutAPIClient.displayString(target)). Use that address instead."
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .invalidCredentials:
            return "Incorrect username or password."
        case .rateLimited:
            return "Too many attempts. Wait a minute and try again."
        case .planNotActive:
            return "This plan was already completed on another device."
        case .serverError(let code):
            switch code {
            case 401, 403: return "Authentication failed — check your credentials"
            case 404: return "Not found — check the server URL"
            default: return "Server returned status \(code)"
            }
        }
    }
}

// MARK: - Auth Models
//
// Pure data models. Marked `nonisolated` because the project defaults types to
// @MainActor (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor); without this their
// Codable conformances would be main-actor-isolated and can't be used from the
// WorkoutAPIClient actor.

nonisolated struct AuthUser: Decodable, Sendable {
    let id: String
    let username: String
    let displayName: String
    let role: String
}

nonisolated struct LoginResponse: Decodable, Sendable {
    let token: String
    let tokenId: String
    let user: AuthUser
}

nonisolated struct AuthToken: Decodable, Sendable {
    let id: String
    let name: String?
    let createdAt: String?
    let lastUsedAt: String?
    let expiresAt: String?
}

nonisolated struct MeResponse: Decodable, Sendable {
    let user: AuthUser
    let tokens: [AuthToken]?
}

// MARK: - Feedback Payload

/// Codable payload mirroring WorkoutFeedback for API submission.
nonisolated struct WorkoutFeedbackPayload: Codable, Sendable {
    let id: UUID
    let workoutId: UUID
    let workoutName: String
    let scheduledDate: Date
    let detectedAt: Date
    let acknowledgedAt: Date?
    let reason: String
    let reasonNote: String?
    let action: String
    let newDate: Date?
    let dismissed: Bool

    /// The same check-in with a reason every server version accepts; nil when
    /// the reason is already one of those.
    var forOlderServer: WorkoutFeedbackPayload? {
        let label: String
        switch reason {
        case "sick": label = "Sick"
        case "injured": label = "Injured"
        default: return nil
        }
        let note = [label, reasonNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        return WorkoutFeedbackPayload(
            id: id, workoutId: workoutId, workoutName: workoutName,
            scheduledDate: scheduledDate, detectedAt: detectedAt, acknowledgedAt: acknowledgedAt,
            reason: "other", reasonNote: note, action: action, newDate: newDate, dismissed: dismissed
        )
    }
}
