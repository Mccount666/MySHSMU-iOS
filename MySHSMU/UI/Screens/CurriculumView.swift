import SwiftUI

/// Port of `ui/screens/CurriculumScreen.kt`.
///
/// The Kotlin screen pages through `Int.MAX_VALUE` weeks; here the pager covers
/// roughly five years either side of today, which is far more than any student
/// needs and keeps `TabView`'s page style happy.
struct CurriculumView: View {
    @Environment(MainViewModel.self) private var viewModel

    @State private var anchorDate = Date()
    @State private var weekOffset = 0
    @State private var selectedCourse: CourseItem?
    @State private var showDetail = false

    /// Roughly a year and a half either side of today. The Kotlin screen pages
    /// through `Int.MAX_VALUE` weeks, but every page is built eagerly during
    /// view diffing, so the range is kept to what a student could plausibly
    /// look at — swiping this far either way feels unbounded in practice.
    private static let weekRange = -78...78

    var body: some View {
        VStack(spacing: 0) {
            Text(weekLabel)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.gridHorizontalPadding)
                .padding(.bottom, 8)

            TabView(selection: $weekOffset) {
                ForEach(Self.weekRange, id: \.self) { offset in
                    WeekSchedulePage(
                        weekStart: AppCalendar.startOfWeek(AppCalendar.addWeeks(offset, to: anchorDate)),
                        courses: viewModel.state.courseList,
                        blockHeight: CGFloat(viewModel.state.courseBlockHeight),
                        onSelect: present
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .padding(.horizontal, AppTheme.gridHorizontalPadding)
        .onAppear {
            viewModel.onWeekPageChanged(weekStart(for: weekOffset))
        }
        .onChange(of: weekOffset) { _, newValue in
            viewModel.onWeekPageChanged(weekStart(for: newValue))
        }
        .overlay {
            if showDetail {
                CourseDetailOverlay(
                    title: selectedCourse?.title ?? "课程详情",
                    detail: viewModel.state.courseDetail,
                    onDismiss: dismissDetail
                )
            }
        }
    }

    // MARK: - Week labelling

    /// The date the label is computed from: same weekday as today, shifted by
    /// the page offset. Mirrors `initialDate.plusWeeks(weekOffset)`.
    private func baseDate(for offset: Int) -> Date {
        AppCalendar.addWeeks(offset, to: anchorDate)
    }

    private func weekStart(for offset: Int) -> Date {
        AppCalendar.startOfWeek(baseDate(for: offset))
    }

    private var weekLabel: String {
        guard let stored = viewModel.state.firstWeekStartDate,
              let firstWeekStart = AppCalendar.date(fromISODate: stored) else {
            return "请设置第一周起始日"
        }

        let current = baseDate(for: weekOffset)
        if firstWeekStart > current { return "学期未开始" }

        let weekNumber = AppCalendar.daysBetween(firstWeekStart, current) / 7 + 1
        if weekNumber > viewModel.state.weekCount { return "学期已结束" }
        return "第 \(weekNumber) 周"
    }

    private func present(_ course: CourseItem) {
        selectedCourse = course
        showDetail = true
        viewModel.onCourseSelected(course)
    }

    private func dismissDetail() {
        showDetail = false
        selectedCourse = nil
    }
}

// MARK: - One week

/// The sticky day header plus the scrollable timetable grid.
struct WeekSchedulePage: View {
    let weekStart: Date
    let courses: [CourseItem]
    let blockHeight: CGFloat
    let onSelect: (CourseItem) -> Void

    var body: some View {
        GeometryReader { geometry in
            let timeColumnWidth = AppTheme.timeColumnWidth
            let dayColumnWidth = max((geometry.size.width - timeColumnWidth) / 7, 1)

            VStack(spacing: 0) {
                header(timeColumnWidth: timeColumnWidth, dayColumnWidth: dayColumnWidth)

                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        TimeGutter(cellHeight: blockHeight, width: timeColumnWidth)
                        grid(dayColumnWidth: dayColumnWidth)
                    }
                }
            }
        }
    }

    private func header(timeColumnWidth: CGFloat, dayColumnWidth: CGFloat) -> some View {
        let today = Date()

        return HStack(spacing: 0) {
            Text(AppCalendar.shortMonth(weekStart))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: timeColumnWidth, height: AppTheme.gridHeaderHeight)

            ForEach(0..<7, id: \.self) { index in
                let date = AppCalendar.addDays(index, to: weekStart)
                let isToday = AppCalendar.daysBetween(date, today) == 0
                let tint = isToday ? AppTheme.accent : Color.primary

                VStack(spacing: 2) {
                    Text(AppCalendar.shortWeekday(date))
                        .font(.system(size: 12, weight: .bold))
                    Text("\(AppCalendar.calendar.component(.day, from: date))")
                        .font(.system(size: 10))
                        .opacity(0.8)
                }
                .foregroundStyle(tint)
                .frame(width: dayColumnWidth, height: AppTheme.gridHeaderHeight)
            }
        }
    }

    private func grid(dayColumnWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // One spacer instead of a cell per period per day: 521 pages' worth
            // of individual cells would be tens of thousands of views for a
            // grid that draws nothing.
            Color.clear
                .frame(
                    width: dayColumnWidth * 7,
                    height: blockHeight * CGFloat(standardTimeSlots.count)
                )

            ForEach(courses) { course in
                if let dayIndex = course.dayIndex(weekStart: weekStart) {
                    let startSlot = SlotResolver.startSlot(
                        forMinutes: AppCalendar.minutesSinceMidnight(course.startTime)
                    )
                    // `CourseCount` says how many periods the class runs for.
                    let rows = max(1, min(course.count, standardTimeSlots.count - startSlot))

                    CourseBlock(course: course)
                        .frame(
                            width: max(dayColumnWidth - 2, 1),
                            height: max(blockHeight * CGFloat(rows) - 2, 1)
                        )
                        .offset(
                            x: dayColumnWidth * CGFloat(dayIndex) + 1,
                            y: blockHeight * CGFloat(startSlot) + 1
                        )
                        .onTapGesture {
                            // Exams are informational, matching the Kotlin guard.
                            if course.type != "考试" { onSelect(course) }
                        }
                }
            }
        }
    }
}

/// A single course card. The palette is baked into the course so the same
/// course keeps the same colour on every screen and every launch.
struct CourseBlock: View {
    let course: CourseItem

    var body: some View {
        VStack(spacing: 0) {
            Text("(\(String(course.type.prefix(2)))) \(course.title)")
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .foregroundStyle(AppTheme.onCourseBlock)

            if !course.location.isEmpty {
                Spacer().frame(height: 10)
                Text("@\(course.location)")
                    .font(.system(size: 8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(1)
                    .foregroundStyle(AppTheme.onCourseBlockSecondary)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CurriculumUtils.color(at: course.colorIndex))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

/// The left-hand column of period labels. Shared with the classroom screen.
struct TimeGutter: View {
    let cellHeight: CGFloat
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(standardTimeSlots, id: \.startMinutes) { slot in
                Text(slot.label)
                    .font(.system(size: 10))
                    .lineSpacing(0)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .frame(width: width, height: cellHeight)
            }
        }
    }
}

// MARK: - Course detail

/// Centred detail card, standing in for the `AlertDialog` in
/// `CourseDetailDialog`.
struct CourseDetailOverlay: View {
    let title: String
    let detail: CourseDetail?
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.accent)
                    .padding(.bottom, 16)

                if let detail {
                    VStack(alignment: .leading, spacing: 12) {
                        row(icon: "info.circle", text: detail.content)
                        row(icon: "person", text: detail.teacher)
                        row(icon: "star", text: detail.college)
                        row(icon: "location", text: detail.location)
                        row(icon: "house", text: detail.classes)
                    }
                } else {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                HStack {
                    Spacer()
                    Button("关闭", action: onDismiss)
                        .fontWeight(.medium)
                        .padding(.top, 16)
                }
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .padding(32)
        }
    }

    private func row(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
