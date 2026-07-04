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
        VStack(spacing: 10) {
            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(.lbBody(14, .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(LB.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
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
        HStack(spacing: 0) {
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
        VStack(spacing: 6) {
            Text(date, format: .dateTime.weekday(.abbreviated))
                .font(.lbBody(12, .semibold))
                .tracking(0.3)
                .foregroundStyle(isSelected ? LB.bg.opacity(0.65) : LB.textTertiary)

            VStack(spacing: 5) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.lbDisplay(19, .semibold))
                    .foregroundStyle(isSelected ? LB.bg : LB.textPrimary)

                HStack(spacing: 3) {
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
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? LB.accent : LB.surfaceAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isToday && !isSelected ? LB.accent : LB.line,
                                  lineWidth: isToday && !isSelected ? 1.5 : 1)
            )
        }
        .padding(.horizontal, 4)
    }
}
