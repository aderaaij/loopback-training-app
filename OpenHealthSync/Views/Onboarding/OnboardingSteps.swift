//
//  OnboardingSteps.swift
//  OpenHealthSync
//
//  The onboarding step screens (welcome/HealthKit, goal, 30-min check,
//  injuries, availability, finishing) plus their shared chrome — top bar,
//  progress dots, buttons. OnboardingView.swift owns the state and switches
//  between these.
//

import SwiftUI

extension OnboardingView {

    // MARK: Shared chrome

    private var topBar: some View {
        HStack {
            if model.canGoBack {
                LBCircleButton(systemName: "chevron.left", size: 38) {
                    withAnimation { model.goBack() }
                }
            }
            Spacer()
            Button {
                withAnimation { model.advance() }
            } label: {
                Text("Skip")
                    .font(.lbBody(.body, .medium))
                    .foregroundStyle(LB.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LB.Space.lg)
        .padding(.top, LB.Space.sm)
    }

    private var progressDots: some View {
        HStack(spacing: LB.Space.sm) {
            let count = model.questionSteps.count
            let pos = model.questionPosition ?? 0
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == pos ? LB.accent : LB.textFaint)
                    .frame(width: i == pos ? 20 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: pos)
            }
        }
    }

    private func primaryButton(_ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.lbBody(.body, .semibold))
                .foregroundStyle(LB.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, LB.Space.lg)
                .background(
                    RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                        .fill(enabled ? LB.accent : LB.surfaceTile)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .padding(.horizontal, LB.Space.lg)
        .padding(.bottom, LB.Space.lg)
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.lbDisplay(.title, .semibold))
            .tracking(-0.4)
            .foregroundStyle(LB.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LB.Space.lg)
    }

    // MARK: Step 0 — Welcome + HealthKit

    var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: LB.Space.xl) {
                Image(systemName: "infinity")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(LB.accent)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(LB.accentTint()))
                    .overlay(Circle().strokeBorder(LB.accent.opacity(0.35), lineWidth: 1))
                    .shadow(color: LB.accent.opacity(0.4), radius: 22)

                VStack(spacing: LB.Space.sm) {
                    Text("Loopback")
                        .font(.lbDisplay(.largeTitle, .bold))
                        .foregroundStyle(LB.textPrimary)
                    Text("Your training history is your coach's memory.")
                        .font(.lbBody(.body))
                        .foregroundStyle(LB.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, LB.Space.xxl)
                }
            }

            Spacer()

            VStack(spacing: LB.Space.md) {
                Text("A few questions so your coach knows who it's training. You choose what it gets to see.")
                    .font(.lbBody(.secondary))
                    .foregroundStyle(LB.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, LB.Space.xxl)

                // No HealthKit prompt here. The system sheet shows once per
                // install and can't be re-shown, so it has to come after the
                // athlete knows what's being asked for and has picked the
                // domains — that's the data-sharing step, two on from here.
                primaryButton("Get started") {
                    withAnimation { model.advance() }
                }
                .padding(.bottom, LB.Space.sm)
            }
        }
    }

    // MARK: Step A2 — What to share

    var dataSharingStep: some View {
        VStack(spacing: 0) {
            // No top-bar skip: this step's own "Not now" is the skip, and it
            // records a real choice instead of leaving intent undefined.
            ScrollView {
                VStack(alignment: .leading, spacing: LB.Space.lg) {
                    progressDots
                        .padding(.horizontal, LB.Space.lg)
                        .padding(.top, LB.Space.xl)
                    stepTitle("What should your coach see?")

                    Text("Everything stays on your own server. Turn any of this off now or later — the coach simply won't be given those tools.")
                        .font(.lbBody(.body))
                        .foregroundStyle(LB.textSecondary)
                        .padding(.horizontal, LB.Space.lg)

                    VStack(spacing: LB.Space.sm) {
                        ForEach(DataDomains.ordered, id: \.rawValue) { domain in
                            domainCard(domain)
                        }
                    }
                    .padding(.horizontal, LB.Space.lg)
                }
                .padding(.bottom, LB.Space.xl)
            }

            VStack(spacing: LB.Space.xs) {
                primaryButton("Connect Apple Health") {
                    Task {
                        await model.connectHealthKit()
                        withAnimation { model.advance() }
                    }
                }

                Button {
                    Task {
                        await model.declineHealthSharing()
                        withAnimation { model.advance() }
                    }
                } label: {
                    Text("Not now — just coach my running")
                        .font(.lbBody(.body, .medium))
                        .foregroundStyle(LB.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, LB.Space.lg)
            }
        }
    }

    private func domainCard(_ domain: DataDomains) -> some View {
        let on = model.sharedDomains.contains(domain)
        let locked = domain.isRequired
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { model.toggleDomain(domain) }
        } label: {
            HStack(spacing: LB.Space.md) {
                RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                    .fill(domain.tint.opacity(on ? 0.16 : 0.08))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: domain.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(domain.tint.opacity(on ? 1 : 0.45))
                    )

                VStack(alignment: .leading, spacing: LB.Space.xs) {
                    Text(domain.title)
                        .font(.lbDisplay(.subheadline, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    Text(domain.rationale)
                        .font(.lbBody(.secondary))
                        .foregroundStyle(LB.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if locked {
                    Text("ALWAYS")
                        .font(.lbMono(.caption))
                        .tracking(0.9)
                        .foregroundStyle(LB.textMuted)
                } else {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .foregroundStyle(on ? domain.tint : LB.textMuted)
                }
            }
            .padding(LB.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbCard(fill: on ? LB.surface : LB.surfaceSunken,
                    border: on ? domain.tint.opacity(0.4) : LB.line)
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    // MARK: Step A — Goal

    var goalStep: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: LB.Space.lg) {
                    progressDots
                        .padding(.horizontal, LB.Space.lg)
                        .padding(.top, LB.Space.sm)
                    stepTitle("What are you working toward?")

                    VStack(spacing: LB.Space.sm) {
                        ForEach(RunGoal.allCases) { goal in
                            goalCard(goal)
                        }
                    }
                    .padding(.horizontal, LB.Space.lg)

                    if let goal = model.goal, goal.isRace {
                        raceDateSection
                            .padding(.horizontal, LB.Space.lg)
                            .padding(.top, LB.Space.xs)
                    }
                }
                .padding(.bottom, LB.Space.xl)
            }
            primaryButton("Continue", enabled: model.goal != nil) {
                withAnimation { model.advance() }
            }
        }
    }

    private func goalCard(_ goal: RunGoal) -> some View {
        let on = model.goal == goal
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { model.goal = goal }
        } label: {
            HStack(spacing: LB.Space.md) {
                VStack(alignment: .leading, spacing: LB.Space.xs) {
                    Text(goal.label)
                        .font(.lbDisplay(.subheadline, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    if let sub = goal.sublabel {
                        Text(sub)
                            .font(.lbBody(.secondary))
                            .foregroundStyle(LB.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(on ? LB.accent : LB.textMuted)
            }
            .padding(LB.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbCard(fill: on ? LB.accentTint(0.10) : LB.surface,
                    border: on ? LB.accent.opacity(0.5) : LB.line)
        }
        .buttonStyle(.plain)
    }

    private var raceDateSection: some View {
        VStack(alignment: .leading, spacing: LB.Space.md) {
            Toggle(isOn: $model.raceDateEnabled.animation()) {
                Text("Racing on a specific date?")
                    .font(.lbBody(.body, .medium))
                    .foregroundStyle(LB.textPrimary)
            }
            .tint(LB.accent)

            if model.raceDateEnabled {
                DatePicker(
                    "",
                    selection: $model.raceDate,
                    in: Date()...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(LB.accent)
                .labelsHidden()
            }
        }
        .padding(LB.Space.lg)
        .lbCard(fill: LB.surfaceAlt, radius: LB.Radius.inner)
    }

    // MARK: Step B — 30-minute check

    var thirtyMinStep: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: LB.Space.lg) {
                    progressDots
                        .padding(.horizontal, LB.Space.lg)
                        .padding(.top, LB.Space.sm)
                    stepTitle("Can you currently run about 30 minutes without stopping?")

                    VStack(spacing: LB.Space.sm) {
                        ForEach(ThirtyMinAnswer.allCases) { answer in
                            selectRow(
                                label: answer.label,
                                on: model.thirtyMin == answer
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) { model.thirtyMin = answer }
                            }
                        }
                    }
                    .padding(.horizontal, LB.Space.lg)
                }
                .padding(.bottom, LB.Space.xl)
            }
            primaryButton("Continue") {
                withAnimation { model.advance() }
            }
        }
    }

    private func selectRow(label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LB.Space.md) {
                Text(label)
                    .font(.lbDisplay(.subheadline, .semibold))
                    .foregroundStyle(LB.textPrimary)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(on ? LB.accent : LB.textMuted)
            }
            .padding(LB.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbCard(fill: on ? LB.accentTint(0.10) : LB.surface,
                    border: on ? LB.accent.opacity(0.5) : LB.line)
        }
        .buttonStyle(.plain)
    }

    // MARK: Step C — Injuries

    var injuriesStep: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: LB.Space.lg) {
                    progressDots
                        .padding(.horizontal, LB.Space.lg)
                        .padding(.top, LB.Space.sm)
                    stepTitle("Any injuries we should train around?")

                    FlowChips(
                        injuries: model.injuries,
                        noneSelected: model.injuriesNone,
                        onToggle: { model.toggleInjury($0) },
                        onNone: { withAnimation { model.selectNoInjuries() } }
                    )
                    .padding(.horizontal, LB.Space.lg)

                    if !model.injuries.isEmpty {
                        TextField(
                            "",
                            text: $model.injuryNote,
                            prompt: Text("When, which side, how it resolved (optional)")
                                .font(.lbBody(.body))
                                .foregroundStyle(LB.textMuted),
                            axis: .vertical
                        )
                        .font(.lbBody(.body))
                        .foregroundStyle(LB.textPrimary)
                        .lineLimit(2...5)
                        .padding(LB.Space.lg)
                        .lbCard(fill: LB.surfaceAlt, radius: LB.Radius.inner)
                        .padding(.horizontal, LB.Space.lg)
                    }
                }
                .padding(.bottom, LB.Space.xl)
            }
            primaryButton("Continue") {
                withAnimation { model.advance() }
            }
        }
    }

    // MARK: Step D — Availability

    var availabilityStep: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: LB.Space.xl) {
                    progressDots
                        .padding(.horizontal, LB.Space.lg)
                        .padding(.top, LB.Space.sm)
                    stepTitle("Which days can you usually train?")

                    weekdayPills
                        .padding(.horizontal, LB.Space.lg)

                    VStack(alignment: .leading, spacing: LB.Space.sm) {
                        LBSectionHeader(title: "Preferred time")
                        timePills
                    }
                    .padding(.horizontal, LB.Space.lg)
                }
                .padding(.bottom, LB.Space.xl)
            }
            primaryButton("Continue") {
                withAnimation { model.advance() }
            }
        }
    }

    private var orderedWeekdays: [Int] {
        weekStartsOnMonday ? [1, 2, 3, 4, 5, 6, 7] : [7, 1, 2, 3, 4, 5, 6]
    }

    private var weekdayPills: some View {
        HStack(spacing: LB.Space.sm) {
            ForEach(orderedWeekdays, id: \.self) { day in
                let on = model.selectedDays.contains(day)
                Text(OnboardingModel.weekdayAbbrev(day))
                    .font(.lbBody(.secondary, .semibold))
                    .foregroundStyle(on ? LB.bg : LB.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LB.Space.md)
                    .background(
                        RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                            .fill(on ? LB.accent : LB.surfaceTile)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) { model.toggleDay(day) }
                    }
            }
        }
    }

    private var timePills: some View {
        HStack(spacing: LB.Space.sm) {
            ForEach(TrainTime.allCases) { time in
                let on = model.trainTime == time
                Text(time.label)
                    .font(.lbBody(.secondary, .medium))
                    .foregroundStyle(on ? LB.accent : LB.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LB.Space.md)
                    .background(
                        RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                            .fill(on ? LB.accentTint() : LB.surfaceTile)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                            .strokeBorder(on ? LB.accent.opacity(0.5) : .clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            model.trainTime = on ? nil : time
                        }
                    }
            }
        }
    }

    // MARK: Final step — seed + done

    var finishingStep: some View {
        VStack(spacing: 0) {
            Spacer()

            switch model.writeState {
            case .idle, .writing:
                VStack(spacing: LB.Space.lg) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(LB.accent)
                    Text("Finishing up…")
                        .font(.lbDisplay(.headline, .semibold))
                        .foregroundStyle(LB.textPrimary)
                }

            case .success:
                VStack(spacing: LB.Space.lg) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(LB.green)
                        .shadow(color: LB.green.opacity(0.5), radius: 20)
                    Text("You're all set")
                        .font(.lbDisplay(.title, .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(LB.textPrimary)
                    if model.seededGoal {
                        Text("Tell your coach you're ready and they'll build your plan.")
                            .font(.lbBody(.body))
                            .foregroundStyle(LB.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, LB.Space.xxl)
                    }
                }

            case .failed:
                VStack(spacing: LB.Space.md) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(LB.amber)
                    Text("Couldn't save your answers")
                        .font(.lbDisplay(.headline, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    Text("Check your connection and try again, or skip for now.")
                        .font(.lbBody(.body))
                        .foregroundStyle(LB.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, LB.Space.xxl)
                }
            }

            Spacer()

            finishingButtons
        }
        .onAppear {
            if model.writeState == .idle {
                Task { await model.seedNotes(mondayFirst: weekStartsOnMonday) }
            }
        }
    }

    @ViewBuilder
    private var finishingButtons: some View {
        switch model.writeState {
        case .success:
            primaryButton("Done") { finish() }
        case .failed:
            VStack(spacing: LB.Space.md) {
                primaryButton("Retry") {
                    Task { await model.seedNotes(mondayFirst: weekStartsOnMonday) }
                }
                Button { finish() } label: {
                    Text("Skip for now")
                        .font(.lbBody(.body, .medium))
                        .foregroundStyle(LB.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LB.Space.md)
                }
                .buttonStyle(.plain)
                .padding(.bottom, LB.Space.lg)
            }
        case .idle, .writing:
            Color.clear.frame(height: 1)
        }
    }

    private func finish() {
        onboardingSeededGoal = model.seededGoal
        Task { await startHealthPipeline() }
        onFinished()
    }
}

// MARK: - Injury chips (wrapping layout)

private struct FlowChips: View {
    let injuries: Set<Injury>
    let noneSelected: Bool
    let onToggle: (Injury) -> Void
    let onNone: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: LB.Space.sm)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: LB.Space.sm) {
            ForEach(Injury.allCases) { injury in
                chip(text: injury.label, on: injuries.contains(injury)) {
                    withAnimation(.easeInOut(duration: 0.12)) { onToggle(injury) }
                }
            }
            chip(text: "None", on: noneSelected, action: onNone)
        }
    }

    private func chip(text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Text(text)
            .font(.lbBody(.body, .medium))
            .foregroundStyle(on ? LB.accent : LB.textSecondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, LB.Space.md)
            .padding(.horizontal, LB.Space.md)
            .background(
                RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                    .fill(on ? LB.accentTint() : LB.surfaceTile)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                    .strokeBorder(on ? LB.accent.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
