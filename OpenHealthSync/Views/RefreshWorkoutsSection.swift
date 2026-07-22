import SwiftUI
import SwiftData

// MARK: - Shared Content

/// The sync button and status indicators, usable in any container.
struct RefreshWorkoutsContent: View {
    var scheduleManager: WorkoutScheduleManager
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button {
            Task {
                await scheduleManager.refreshFromServer(modelContext: modelContext)
            }
        } label: {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Sync Workouts")
                Spacer()
            }
        }
        .disabled(isBusy)

        if isBusy {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: syncProgress, total: 1.0)
                    .tint(.accentColor)
                Text(syncLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if case .done(let count) = scheduleManager.refreshState {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(count == 0 ? "All workouts up to date" : "\(count) workout\(count == 1 ? "" : "s") scheduled")
                    .foregroundStyle(.secondary)
            }
        }

        if case .failed(let message) = scheduleManager.refreshState {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var isBusy: Bool {
        switch scheduleManager.refreshState {
        case .syncing, .scheduling:
            return true
        default:
            return false
        }
    }

    private var syncProgress: Double {
        switch scheduleManager.refreshState {
        case .syncing(let step):
            return step.progress
        case .scheduling(let current, let total):
            guard total > 0 else { return 1.0 }
            return Double(current) / Double(total)
        default:
            return 0
        }
    }

    private var syncLabel: String {
        switch scheduleManager.refreshState {
        case .syncing(let step):
            return step.label
        case .scheduling(let current, let total):
            return "Scheduling \(current) of \(total)…"
        default:
            return ""
        }
    }
}

// MARK: - List Section Wrapper

/// Wraps `RefreshWorkoutsContent` in a `Section` for use inside a `List`.
struct RefreshWorkoutsSection: View {
    var scheduleManager: WorkoutScheduleManager

    var body: some View {
        Section {
            RefreshWorkoutsContent(scheduleManager: scheduleManager)
        }
    }
}
