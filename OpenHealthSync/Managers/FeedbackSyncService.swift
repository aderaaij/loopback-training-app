//
//  FeedbackSyncService.swift
//  OpenHealthSync
//
//  Uploads missed-workout feedback to the training API and keeps the local
//  SwiftData entries' `synced` flag honest. Uploads are best-effort: a failed
//  attempt stays unsynced and is retried by the next refresh cycle.
//

import Foundation
import SwiftData
import os

final class FeedbackSyncService {
    private let apiClient: WorkoutAPIClient

    init(apiClient: WorkoutAPIClient) {
        self.apiClient = apiClient
    }

    /// Fire-and-forget upload of feedback to the training API.
    /// Marks the SwiftData entry as synced on success.
    func syncFeedback(_ payload: WorkoutFeedbackPayload, feedbackId: UUID, modelContext: ModelContext) {
        Task {
            do {
                try await apiClient.submitFeedback(payload)
                markFeedbackSynced(id: feedbackId, modelContext: modelContext)
            } catch {
                AppLog.sync.error("Feedback sync failed (will retry on next sync): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Retry uploading any feedback entries that haven't been synced yet.
    /// Called during the refresh flow to catch entries that failed on first attempt.
    func syncUnsyncedFeedback(modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<WorkoutFeedback>(
            predicate: #Predicate<WorkoutFeedback> { $0.synced == false }
        )
        guard let unsynced = try? modelContext.fetch(descriptor), !unsynced.isEmpty else {
            return
        }

        for feedback in unsynced {
            let payload = WorkoutFeedbackPayload(
                id: feedback.id,
                workoutId: feedback.workoutId,
                workoutName: feedback.workoutName,
                scheduledDate: feedback.scheduledDate,
                detectedAt: feedback.detectedAt,
                acknowledgedAt: feedback.acknowledgedAt,
                reason: feedback.reason.rawValue,
                reasonNote: feedback.reasonNote,
                action: feedback.action.rawValue,
                newDate: feedback.newDate,
                dismissed: feedback.dismissed
            )
            do {
                try await apiClient.submitFeedback(payload)
                feedback.synced = true
            } catch {
                AppLog.sync.error("Retry sync failed for feedback \(feedback.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        try? modelContext.save()
    }

    private func markFeedbackSynced(id: UUID, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<WorkoutFeedback>(
            predicate: #Predicate<WorkoutFeedback> { $0.id == id }
        )
        if let feedback = try? modelContext.fetch(descriptor).first {
            feedback.synced = true
            try? modelContext.save()
        }
    }
}
