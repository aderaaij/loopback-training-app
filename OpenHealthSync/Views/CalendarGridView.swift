import SwiftUI

// MARK: - Week Strip View

struct WeekStripView: View {
    let timelineItems: [DateComponents: [TrainingTimelineItem]]
    @Binding var selectedDate: Date

    @State private var scrolledWeek: Date?
    @AppStorage("weekStartsOnMonday") private var weekStartsOnMonday: Bool = true

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = weekStartsOnMonday ? 2 : 1  // 2 = Monday, 1 = Sunday
        return cal
    }

    /// Generate week start dates: 13 weeks back and 13 weeks forward from today.
    private var weekStarts: [Date] {
        let today = Date()
        guard let todayWeekStart = startOfWeek(containing: today) else { return [] }
        return (-13...13).compactMap {
            calendar.date(byAdding: .weekOfYear, value: $0, to: todayWeekStart)
        }
    }

    /// The date used for the month/year header — derived from the visible week.
    private var displayedMonth: Date {
        if let week = scrolledWeek {
            // Use the middle of the week (Wed/Thu) to determine the displayed month,
            // so a week spanning two months shows the month with more days visible.
            return calendar.date(byAdding: .day, value: 3, to: week) ?? week
        }
        return selectedDate
    }

    var body: some View {
        VStack(spacing: LB.Space.sm) {
            LBSectionHeader(title: displayedMonth.formatted(.dateTime.month(.wide).year()))
                .lbScreenEdge()
                .animation(.none, value: displayedMonth)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(weekStarts, id: \.self) { weekStart in
                        weekRow(for: weekStart)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolledWeek)
            .frame(height: 88)
        }
        .onAppear {
            scrolledWeek = startOfWeek(containing: selectedDate)
        }
    }

    // MARK: - Week Row

    private func weekRow(for weekStart: Date) -> some View {
        HStack(spacing: LB.Space.sm) {
            ForEach(daysInWeek(from: weekStart), id: \.self) { date in
                WeekDayCell(
                    date: date,
                    isToday: calendar.isDateInToday(date),
                    isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                    dotCategories: dotCategories(for: date)
                )
                .onTapGesture {
                    selectedDate = date
                }
                .frame(maxWidth: .infinity)
            }
        }
        // Each week is a full-width page, so the screen edge goes inside it.
        .lbScreenEdge()
    }

    // MARK: - Helpers

    private func startOfWeek(containing date: Date) -> Date? {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components)
    }

    private func daysInWeek(from weekStart: Date) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private func dotCategories(for date: Date) -> Set<TrainingTimelineItem.DotCategory> {
        let dc = calendar.dateComponents([.year, .month, .day], from: date)
        guard let items = timelineItems[dc] else { return [] }
        return Set(items.map(\.dotCategory))
    }
}

// MARK: - Week Day Cell

struct WeekDayCell: View {
    let date: Date
    let isToday: Bool
    let isSelected: Bool
    let dotCategories: Set<TrainingTimelineItem.DotCategory>

    var body: some View {
        VStack(spacing: LB.Space.sm) {
            Text(date, format: .dateTime.weekday(.abbreviated))
                .font(.lbBody(.caption, .semibold))
                .tracking(0.3)
                // The label sits above the tile, on the screen background — the
                // tile's on-accent colour would be invisible here.
                .foregroundStyle(isSelected ? LB.accent : LB.textTertiary)

            VStack(spacing: LB.Space.xs) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.lbDisplay(.headline, .semibold))
                    .foregroundStyle(isSelected ? LB.bg : LB.textPrimary)

                HStack(spacing: LB.Space.xs) {
                    if dotCategories.contains(.upcomingPlan) {
                        Circle().fill(LB.blue).frame(width: 5, height: 5)
                    }
                    if dotCategories.contains(.strengthSession) {
                        Circle().fill(LB.violet).frame(width: 5, height: 5)
                    }
                    if dotCategories.contains(.completedPlan) {
                        Circle().fill(LB.green).frame(width: 5, height: 5)
                    }
                    if dotCategories.contains(.pastWorkout) {
                        Circle().fill(LB.amber).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            // Only the selected day and today are drawn as shapes. Seven
            // boxed days read as seven buttons of equal weight.
            .background(
                RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                    .fill(isSelected ? LB.accent : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                    .strokeBorder(isToday && !isSelected ? LB.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
    }
}
