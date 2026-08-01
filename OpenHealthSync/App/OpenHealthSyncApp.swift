//
//  OpenHealthSyncApp.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 13/03/2026.
//

import SwiftUI
import SwiftData
import WorkoutKit
import os

@main
struct LoopbackApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var workoutManager: WorkoutManager
    @State private var scheduleManager: WorkoutScheduleManager
    @State private var missedWorkoutDetector = MissedWorkoutDetector()
    @State private var notificationManager: NotificationManager
    @State private var backgroundSyncManager: BackgroundSyncManager
    @State private var session: SessionStore

    @AppStorage("preferredRunTime") private var preferredRunTime: String = PreferredRunTime.morning.rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    /// The athlete's intent. `migrateIfNeeded()` in `init` guarantees the key
    /// exists, so the default here is only a formality.
    @AppStorage(DataConsent.appStorageKey) private var domainsRaw: Int = DataDomains.required.rawValue

    private var domains: DataDomains { DataDomains(rawValue: domainsRaw).union(.required) }

    @Environment(\.scenePhase) private var scenePhase

    private let apiClient: WorkoutAPIClient
    private let healthMetricsSyncer: HealthMetricsSyncer

    init() {
        // Establish data-sharing intent before anything can read it: on an
        // upgrade this carries the old single sync switch across, and on a
        // fresh install it sets the floor for onboarding to build on.
        DataConsent.migrateIfNeeded()

        // Resolve the current credentials (migrating any legacy API key into the
        // Keychain) so the live clients are configured synchronously at launch.
        let creds = SessionStore.resolveCredentials()
        let alternativeURL = SessionStore.storedAlternativeURL?.absoluteString

        let client = WorkoutAPIClient(
            baseURL: creds.serverURL,
            alternativeURL: alternativeURL,
            apiKey: creds.token
        )
        self.apiClient = client

        let syncer = HealthMetricsSyncer(apiClient: client)
        self.healthMetricsSyncer = syncer

        let wm = WorkoutManager()
        wm.configure(serverURL: creds.serverURL, alternativeURL: alternativeURL, apiKey: creds.token)
        let sm = WorkoutScheduleManager(apiClient: client)
        wm.scheduleManager = sm
        let nm = NotificationManager()
        sm.notificationManager = nm
        _workoutManager = State(initialValue: wm)
        _scheduleManager = State(initialValue: sm)
        _notificationManager = State(initialValue: nm)
        _backgroundSyncManager = State(initialValue: BackgroundSyncManager(
            workoutManager: wm,
            healthMetricsSyncer: syncer
        ))
        _session = State(initialValue: SessionStore(apiClient: client, workoutManager: wm))
    }

    var body: some Scene {
        WindowGroup {
            appRoot
                .tint(LB.accent)
                .preferredColorScheme(.dark) // Loopback is a dark-only, warm-black theme
        }
        .modelContainer(for: WorkoutFeedback.self)
    }

    @ViewBuilder
    private var appRoot: some View {
        if !session.isAuthenticated {
            NavigationStack {
                LoginView(session: session)
            }
        } else if !hasCompletedOnboarding {
            // First run after login: seed the coach's memory. Skippable, and
            // it owns the HealthKit prompt so the system sheet never covers
            // the intro (the post-login `.task` HK block is gated below).
            OnboardingView(
                apiClient: apiClient,
                healthMetricsSyncer: healthMetricsSyncer,
                onFinished: { hasCompletedOnboarding = true },
                startHealthPipeline: { await startHealthPipeline() }
            )
            .onReceive(NotificationCenter.default.publisher(for: .trainingAPIUnauthorized)) { _ in
                session.handleUnauthorized()
            }
        } else {
            MainTabView(
                workoutManager: workoutManager,
                scheduleManager: scheduleManager,
                missedWorkoutDetector: missedWorkoutDetector,
                session: session,
                healthMetricsSyncer: healthMetricsSyncer,
                onReconnect: { baseURL, token in
                    // Advanced: swap in a manually pasted token, then refresh.
                    try await session.applyManualToken(serverURL: baseURL, token: token)
                    await reloadAll()
                }
            )
            .environment(scheduleManager)
            // Any /api call returning 401 signals a dead session → sign out.
            .onReceive(NotificationCenter.default.publisher(for: .trainingAPIUnauthorized)) { _ in
                session.handleUnauthorized()
            }
            .onAppear {
                Task {
                    // Only prompt once the user is actually signed in.
                    guard session.isAuthenticated else { return }
                    await notificationManager.requestPermission()
                }
            }
            .task {
                // MainTabView only renders when authenticated, but an in-flight
                // task can outlive a sign-out (e.g. a 401 mid-session); guard so
                // permission prompts never fire on the way to the login screen.
                guard session.isAuthenticated else { return }

                await scheduleManager.requestAuthorization()
                await scheduleManager.loadScheduledWorkouts()
                await scheduleManager.autoSync()
                // Loads the active plan, and offers the wrap-up celebration
                // if the server says one is finishable.
                await scheduleManager.checkForFinishablePlan()

                // HealthKit auth + first sync + background observers. During
                // onboarding the flow owns this (so the system sheet doesn't
                // cover the intro) and calls startHealthPipeline() itself on
                // completion; here it only runs for already-onboarded users.
                if hasCompletedOnboarding {
                    await startHealthPipeline()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await scheduleManager.loadScheduledWorkouts()
                        await scheduleManager.autoSync()
                        // Refresh the plan on foreground: `finishable` is
                        // recomputed on every read, so a plan whose window
                        // quietly lapsed gets picked up here.
                        await scheduleManager.checkForFinishablePlan()
                        await detectAndNotify()

                        // Sync health metrics on foreground. No consent check
                        // here — `syncMetrics` reads the athlete's domains and
                        // returns early when there's nothing shared.
                        try? await healthMetricsSyncer.syncMetrics()
                    }
                }
            }
            // Consent changed in Settings: ask for any newly shared domains,
            // rebuild the observer set, and tell the server — which is what
            // narrows the coach's tools.
            .onChange(of: domainsRaw) { _, _ in
                Task { await startHealthPipeline() }
            }
        }
    }

    /// HealthKit authorization + first metrics sync + background-observer
    /// registration, all scoped to the domains the athlete shares. Called from
    /// the post-login `.task` for onboarded users, from `OnboardingView` on
    /// completion (the `.task` HK block is gated off during onboarding), and
    /// again whenever consent changes.
    ///
    /// Idempotent: HealthKit only sheets for types it hasn't asked about, and
    /// `setUp(domains:)` no-ops when the domain set is unchanged.
    private func startHealthPipeline() async {
        let domains = self.domains
        await healthMetricsSyncer.requestAuthorization(for: domains)
        try? await healthMetricsSyncer.syncMetrics()
        await backgroundSyncManager.setUp(domains: domains)

        // Best-effort: a server that predates the endpoint 404s, and the app
        // stays fully usable — the coach just sees the tools it saw before.
        do {
            try await apiClient.sendDataConsent(DataConsentPayload(domains))
        } catch {
            AppLog.health.error("Data-consent push failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Refreshes everything after a credential change so it takes effect
    /// immediately instead of only after the next app launch.
    private func reloadAll() async {
        await scheduleManager.loadScheduledWorkouts()
        await scheduleManager.autoSync()
        await scheduleManager.loadActivePlan()
        try? await healthMetricsSyncer.syncMetrics()
    }

    private func detectAndNotify() async {
        guard let container = try? ModelContainer(for: WorkoutFeedback.self) else { return }
        let context = ModelContext(container)

        missedWorkoutDetector.checkForMissedWorkouts(
            scheduledWorkouts: scheduleManager.scheduledWorkouts,
            modelContext: context
        )

        if !missedWorkoutDetector.missedWorkouts.isEmpty {
            let runTime = PreferredRunTime(rawValue: preferredRunTime) ?? .morning
            await notificationManager.scheduleMissedWorkoutNotification(
                workouts: missedWorkoutDetector.missedWorkouts,
                preferredRunTime: runTime
            )
        } else {
            await notificationManager.cancelPendingMissedWorkoutNotifications()
        }
    }
}
