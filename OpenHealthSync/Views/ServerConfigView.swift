import SwiftUI
#if DEBUG
import PulseUI
#endif

struct ServerConfigView: View {
    enum Mode {
        case onboarding
        case settings
    }

    let mode: Mode
    var session: SessionStore? = nil
    var onSave: ((_ baseURL: String, _ apiKey: String) async throws -> Void)? = nil
    var onSignOut: (() -> Void)? = nil
    var onRemoveAllWorkouts: (() async -> Void)? = nil

    @State private var showRemoveAllConfirmation = false

    #if DEBUG
    @StateObject private var seeder = DebugWorkoutSeeder()
    @State private var markSeededAsSynced = true
    @State private var showDeleteSeededConfirmation = false
    #endif

    // Training API fields
    @State private var trainingScheme: ServerScheme = .http
    @State private var trainingHost = ""
    @State private var trainingAPIKey = ""
    @State private var apiKeyVisible = false
    @State private var status: ConnectionStatus = .idle

    // Persisted config
    @AppStorage("trainingAPIBaseURL") private var storedBaseURL: String = ""
    @AppStorage("trainingAPIKey") private var storedAPIKey: String = ""
    @AppStorage("preferredRunTime") private var preferredRunTime: String = PreferredRunTime.morning.rawValue
    @AppStorage("healthMetricsSyncEnabled") private var healthMetricsSyncEnabled: Bool = true
    @AppStorage("weekStartsOnMonday") private var weekStartsOnMonday: Bool = true
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue

    var body: some View {
        Form {
            if mode == .onboarding {
                onboardingContent
            } else {
                settingsContent
            }
        }
        .lbList()
        .navigationTitle(mode == .onboarding ? "Welcome to Loopback" : "Settings")
        .onAppear {
            if mode == .settings {
                if !storedBaseURL.isEmpty {
                    (trainingScheme, trainingHost) = ServerScheme.split(storedBaseURL)
                }
                trainingAPIKey = storedAPIKey
            }
        }
        .onChange(of: trainingScheme) { _, _ in resetStatus() }
        .onChange(of: trainingHost) { _, _ in resetStatus() }
        .onChange(of: trainingAPIKey) { _, _ in resetStatus() }
    }

    // MARK: - Onboarding

    private var onboardingContent: some View {
        Group {
            Section {
                Text("Connect Loopback to your training API to sync workouts, schedule training plans, and track health metrics.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Training API") {
                trainingAPIFields
            }

            Section("When do you usually run?") {
                runTimePicker
            }

            Section {
                Button { save() } label: { saveButtonLabel("Connect") }
                    .disabled(saveDisabled)

                connectionStatusRow
            }
        }
        .listRowBackground(LB.surface)
    }

    // MARK: - Settings

    private var settingsContent: some View {
        Group {
            Section("Account") {
                if let session {
                    HStack {
                        Text("Signed in as")
                        Spacer()
                        Text(session.accountLabel)
                            .foregroundStyle(.secondary)
                    }
                    ServerStatusRow()
                    if !session.serverURL.isEmpty {
                        HStack {
                            Text("Server")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(session.serverURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                DisclosureGroup("Advanced — replace token") {
                    Text("Paste a new token to switch credentials without signing out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    trainingAPIFields

                    Button { save() } label: { saveButtonLabel("Save & Reconnect") }
                        .disabled(saveDisabled)

                    connectionStatusRow
                }
            }

            Section("Health Metrics") {
                Toggle("Sync health data to Training API", isOn: $healthMetricsSyncEnabled)
                    .tint(LB.green)

                if healthMetricsSyncEnabled {
                    Text("Sleep, heart rate, HRV, weight, VO2Max, steps, and more are synced daily to your training server for AI coaching context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Preferences") {
                runTimePicker

                Picker("Week starts on", selection: $weekStartsOnMonday) {
                    Text("Monday").tag(true)
                    Text("Sunday").tag(false)
                }

                Picker("Appearance", selection: Binding(
                    get: { AppearanceMode(rawValue: appearanceMode) ?? .system },
                    set: { appearanceMode = $0.rawValue }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            if let onRemoveAllWorkouts {
                Section("Danger Zone") {
                    Button("Remove All Scheduled Workouts", role: .destructive) {
                        showRemoveAllConfirmation = true
                    }
                    .confirmationDialog(
                        "Remove all scheduled workouts from Apple Watch?",
                        isPresented: $showRemoveAllConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Remove All", role: .destructive) {
                            Task { await onRemoveAllWorkouts() }
                        }
                    }
                }
            }

            if let onSignOut {
                Section {
                    Button("Sign Out", role: .destructive) {
                        onSignOut()
                    }
                } footer: {
                    Text("Signs out this device and returns to the login screen.")
                }
            }

            #if DEBUG
            networkLogSection
            developerSection
            #endif

            Section {
                brandFooter
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listRowBackground(LB.surface)
    }

    #if DEBUG
    // MARK: - Network Log (debug builds only)

    private var networkLogSection: some View {
        Section {
            NavigationLink("Network Log") {
                ConsoleView(mode: .network)
                    .closeButtonHidden()
            }
        } header: {
            Text("Network")
        } footer: {
            Text("Debug builds only. Every Training API request is recorded on-device by Pulse, with the Authorization header redacted.")
        }
    }

    // MARK: - Developer (debug builds only)

    private var developerSection: some View {
        Section {
            Toggle("Mark seeded runs as synced", isOn: $markSeededAsSynced)
                .tint(LB.green)

            Button {
                Task { await seeder.seed(markAsSynced: markSeededAsSynced) }
            } label: {
                if seeder.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(LB.accent)
                        Text("Working…")
                    }
                } else {
                    Text("Seed Sample Workouts")
                }
            }
            .disabled(seeder.isWorking)

            Button("Delete Seeded Data", role: .destructive) {
                showDeleteSeededConfirmation = true
            }
            .disabled(seeder.isWorking)
            .confirmationDialog(
                "Delete every workout and sample this app wrote to HealthKit?",
                isPresented: $showDeleteSeededConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await seeder.deleteSeeded() }
                }
            }

            if let message = seeder.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Debug builds only. Seeds ~6 months of fake runs and strength sessions into HealthKit. Leave \"mark as synced\" on unless this device is signed into a test account — otherwise background sync uploads the fake workouts to your server.")
        }
    }
    #endif

    // MARK: - Brand Footer

    private var brandFooter: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96)
            Text("Loopback")
                .font(.lbDisplay(22, .semibold))
                .tracking(-0.4)
                .foregroundStyle(LB.textPrimary)
            Text("SELF-HOSTED TRAINING · v1.0")
                .font(.lbMono(10.5))
                .tracking(1)
                .foregroundStyle(LB.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    // MARK: - Connection

    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private var saveDisabled: Bool {
        ServerScheme.compose(trainingScheme, trainingHost).isEmpty
            || trainingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status == .connecting
    }

    private func save() {
        let url = ServerScheme.compose(trainingScheme, trainingHost)
        let key = trainingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        status = .connecting
        Task { @MainActor in
            do {
                try await onSave?(url, key)
                status = .connected
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func resetStatus() {
        if status != .connecting { status = .idle }
    }

    @ViewBuilder
    private func saveButtonLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            if status == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(LB.accent)
            }
            Text(status == .connecting ? "Connecting…" : title)
        }
    }

    @ViewBuilder
    private var connectionStatusRow: some View {
        switch status {
        case .idle, .connecting:
            EmptyView()
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(LB.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Shared Components

    private var trainingAPIFields: some View {
        Group {
            ServerURLInput(scheme: $trainingScheme, host: $trainingHost)

            HStack {
                if apiKeyVisible {
                    TextField("API Token", text: $trainingAPIKey)
                        .textContentType(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("API Token", text: $trainingAPIKey)
                        .textContentType(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button {
                    apiKeyVisible.toggle()
                } label: {
                    Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var runTimePicker: some View {
        Picker("Preferred time", selection: Binding(
            get: { PreferredRunTime(rawValue: preferredRunTime) ?? .morning },
            set: { preferredRunTime = $0.rawValue }
        )) {
            ForEach(PreferredRunTime.allCases) { time in
                Text("\(time.label) — \(time.description)").tag(time)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

#Preview("Onboarding") {
    NavigationStack {
        ServerConfigView(mode: .onboarding) { _, _ in }
    }
}

#Preview("Settings") {
    NavigationStack {
        ServerConfigView(mode: .settings, onSave: { _, _ in }, onSignOut: {})
    }
}
