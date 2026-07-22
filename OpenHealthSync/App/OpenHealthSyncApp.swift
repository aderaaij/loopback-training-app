//
//  OpenHealthSyncApp.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 13/03/2026.
//

import SwiftUI
import SwiftData
import WorkoutKit

@main
struct LoopbackApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var workoutManager: WorkoutManager
    @StateObject private var scheduleManager: WorkoutScheduleManager
    @StateObject private var missedWorkoutDetector = MissedWorkoutDetector()
    @StateObject private var notificationManager: NotificationManager
    @StateObject private var backgroundSyncManager: BackgroundSyncManager
    @StateObject private var session: SessionStore

    @AppStorage("preferredRunTime") private var preferredRunTime: String = PreferredRunTime.morning.rawValue
    @AppStorage("healthMetricsSyncEnabled") private var healthMetricsSyncEnabled: Bool = true
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    @Environment(\.scenePhase) private var scenePhase

    private let apiClient: WorkoutAPIClient
    private let healthMetricsSyncer: HealthMetricsSyncer

    init() {
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
        _workoutManager = StateObject(wrappedValue: wm)
        _scheduleManager = StateObject(wrappedValue: sm)
        _notificationManager = StateObject(wrappedValue: nm)
        _backgroundSyncManager = StateObject(wrappedValue: BackgroundSyncManager(
            workoutManager: wm,
            healthMetricsSyncer: syncer
        ))
        _session = StateObject(wrappedValue: SessionStore(apiClient: client, workoutManager: wm))
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
                onReconnect: { baseURL, token in
                    // Advanced: swap in a manually pasted token, then refresh.
                    try await session.applyManualToken(serverURL: baseURL, token: token)
                    await reloadAll()
                }
            )
            .environmentObject(scheduleManager)
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

                        // Sync health metrics on foreground
                        if healthMetricsSyncEnabled {
                            try? await healthMetricsSyncer.syncMetrics()
                        }
                    }
                }
            }
        }
    }

    /// HealthKit authorization + first metrics sync + background-observer
    /// registration. Called from the post-login `.task` for onboarded users,
    /// and from `OnboardingView` on completion (the `.task` HK block is gated
    /// off during onboarding). Idempotent — the system auth sheet shows once.
    private func startHealthPipeline() async {
        if healthMetricsSyncEnabled {
            _ = await healthMetricsSyncer.requestAuthorization()
            try? await healthMetricsSyncer.syncMetrics()
        }
        await backgroundSyncManager.setUp()
    }

    /// Refreshes everything after a credential change so it takes effect
    /// immediately instead of only after the next app launch.
    private func reloadAll() async {
        await scheduleManager.loadScheduledWorkouts()
        await scheduleManager.autoSync()
        await scheduleManager.loadActivePlan()
        if healthMetricsSyncEnabled {
            try? await healthMetricsSyncer.syncMetrics()
        }
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
