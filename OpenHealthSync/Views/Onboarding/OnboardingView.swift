//
//  OnboardingView.swift
//  OpenHealthSync
//
//  First-run onboarding: a skippable flow that seeds the coach LLM's memory.
//  After login a new athlete answers goal / what to share / 30-min check /
//  injuries / availability. Each answer becomes a plan note (conversationId
//  "ios-onboarding") via the training API. Skipping everything leaves the app
//  fully functional and writes nothing.
//
//  The data-sharing step owns the HealthKit prompt, and sits after the goal so
//  the athlete knows what they're being asked for before the system sheet
//  appears — and so we only ask for the domains they actually chose.
//

import SwiftUI

// MARK: - Onboarding View

struct OnboardingView: View {
    @State var model: OnboardingModel
    let onFinished: () -> Void
    /// Whatever the gated `.task` HK block would have done — called on finish.
    let startHealthPipeline: () async -> Void

    @AppStorage("weekStartsOnMonday") var weekStartsOnMonday: Bool = true
    @AppStorage("onboardingSeededGoal") var onboardingSeededGoal: Bool = false

    init(
        apiClient: WorkoutAPIClient,
        healthMetricsSyncer: HealthMetricsSyncer,
        onFinished: @escaping () -> Void,
        startHealthPipeline: @escaping () async -> Void
    ) {
        _model = State(initialValue: OnboardingModel(
            apiClient: apiClient,
            healthMetricsSyncer: healthMetricsSyncer
        ))
        self.onFinished = onFinished
        self.startHealthPipeline = startHealthPipeline
    }

    var body: some View {
        ZStack {
            LB.bg.ignoresSafeArea()

            Group {
                switch model.currentStep {
                case .welcome:      welcomeStep
                case .goal:         goalStep
                case .dataSharing:  dataSharingStep
                case .thirtyMin:    thirtyMinStep
                case .injuries:     injuriesStep
                case .availability: availabilityStep
                case .finishing:    finishingStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            ))
            .id(model.stepIndex)
        }
        .animation(.easeInOut(duration: 0.25), value: model.stepIndex)
    }
}
