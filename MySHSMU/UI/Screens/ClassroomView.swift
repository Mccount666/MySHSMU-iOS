import SwiftUI

/// Port of `ui/screens/ClassroomScreen.kt`: pick a room through the
/// campus → building → floor → room cascade, then page through its day-by-day
/// occupancy.
struct ClassroomView: View {
    @Environment(MainViewModel.self) private var viewModel

    @State private var anchorDate = Date()
    @State private var dayOffset = 0

    /// Four months either side of today; see `CurriculumView.weekRange` for why
    /// this is bounded rather than `Int.MAX_VALUE` as on Android.
    private static let dayRange = -120...120

    private var state: MySHSMUUiState { viewModel.state }

    private var isBusy: Bool {
        state.isClassroomOptionsLoading || state.isClassroomScheduleLoading
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ClassroomSelector(
                        label: "校区",
                        options: state.classroomCampusOptions,
                        selectedCode: state.selectedCampusCode,
                        enabled: true,
                        onSelect: viewModel.onCampusSelected
                    )
                    ClassroomSelector(
                        label: "楼栋",
                        options: state.classroomBuildingOptions,
                        selectedCode: state.selectedBuildingCode,
                        enabled: !(state.selectedCampusCode ?? "").isEmpty,
                        onSelect: viewModel.onBuildingSelected
                    )
                }
                HStack(spacing: 8) {
                    ClassroomSelector(
                        label: "楼层",
                        options: state.classroomFloorOptions,
                        selectedCode: state.selectedFloorCode,
                        enabled: !(state.selectedBuildingCode ?? "").isEmpty,
                        onSelect: viewModel.onFloorSelected
                    )
                    ClassroomSelector(
                        label: "教室",
                        options: state.classroomRoomOptions,
                        selectedCode: state.selectedClassroomCode,
                        enabled: !(state.selectedFloorCode ?? "").isEmpty,
                        onSelect: viewModel.onClassroomSelected
                    )
                }
            }
            .padding(.horizontal, 12)

            Spacer().frame(height: 8)

            Text(AppCalendar.longDateWithWeekday(currentDate))
                .font(.headline)
                .foregroundStyle(AppTheme.accent)
                .padding(.vertical, 4)

            TabView(selection: $dayOffset) {
                ForEach(Self.dayRange, id: \.self) { offset in
                    DayClassroomSchedule(
                        items: state.classroomScheduleList,
                        hasSelection: !(state.selectedClassroomCode ?? "").isEmpty,
                        blockHeight: CGFloat(state.courseBlockHeight)
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .disabled(isBusy)
        }
        .onAppear {
            viewModel.ensureClassroomOptionsLoaded()
        }
        .onChange(of: dayOffset) { _, newValue in
            guard !(state.selectedClassroomCode ?? "").isEmpty else { return }
            viewModel.fetchClassroomSchedule(AppCalendar.addDays(newValue, to: anchorDate))
        }
        .onChange(of: state.selectedClassroomCode) { _, newValue in
            guard !(newValue ?? "").isEmpty else { return }
            viewModel.fetchClassroomSchedule(currentDate)
        }
        .overlay {
            if isBusy {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial.opacity(0.6))
            }
        }
    }

    private var currentDate: Date {
        AppCalendar.addDays(dayOffset, to: anchorDate)
    }
}

/// Outlined menu standing in for `ExposedDropdownMenuBox`.
private struct ClassroomSelector: View {
    let label: String
    let options: [ClassroomOption]
    let selectedCode: String?
    let enabled: Bool
    let onSelect: (String) -> Void

    private var selectedName: String {
        options.first { $0.code == selectedCode }?.name ?? "请选择"
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button(option.name) { onSelect(option.code) }
            }
        } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(selectedName)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(selectedCode == nil ? .secondary : .primary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .opacity(enabled ? 1 : 0.45)
        }
        .disabled(!enabled || options.isEmpty)
    }
}

/// One day of room occupancy, laid out on the same period grid as the
/// timetable.
private struct DayClassroomSchedule: View {
    let items: [ClassroomScheduleItem]
    let hasSelection: Bool
    let blockHeight: CGFloat

    var body: some View {
        if !hasSelection {
            VStack {
                Spacer()
                Text("请先选择完整的校区、楼栋、楼层和教室")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
        } else {
            GeometryReader { geometry in
                let timeColumnWidth = AppTheme.timeColumnWidth
                let scheduleWidth = max(geometry.size.width - timeColumnWidth, 1)

                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        TimeGutter(cellHeight: blockHeight, width: timeColumnWidth)

                        ZStack(alignment: .topLeading) {
                            // Single sized spacer rather than a cell per period.
                            Color.clear
                                .frame(
                                    width: scheduleWidth,
                                    height: blockHeight * CGFloat(standardTimeSlots.count)
                                )

                            ForEach(items) { item in
                                block(for: item, width: scheduleWidth)
                            }
                        }
                    }
                }
            }
        }
    }

    private func block(for item: ClassroomScheduleItem, width: CGFloat) -> some View {
        let startSlot = SlotResolver.startSlot(forMinutes: item.beginMinutes)
        let rows = SlotResolver.slotCount(
            startSlot: startSlot,
            beginMinutes: item.beginMinutes,
            endMinutes: item.endMinutes
        )

        return VStack(spacing: 0) {
            Text(item.courseName)
                .font(.system(size: 12, weight: .bold))
                .lineSpacing(1)
                .multilineTextAlignment(.center)

            if !item.teacher.isEmpty {
                Spacer().frame(height: 5)
                Text(item.teacher)
                    .font(.system(size: 10))
                    .lineSpacing(1)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !item.className.isEmpty {
                Spacer().frame(height: 5)
                Text(item.className)
                    .font(.system(size: 10))
                    .lineSpacing(1)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !item.content.isEmpty && item.content != "-" {
                Spacer().frame(height: 5)
                Text(item.content)
                    .font(.system(size: 10))
                    .lineSpacing(1)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(containerColor(for: item.category))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
        .frame(width: max(width - 8, 1), height: max(blockHeight * CGFloat(rows) - 2, 1))
        .offset(x: 4, y: blockHeight * CGFloat(startSlot))
    }

    private func containerColor(for category: String) -> Color {
        if category.contains("自习") { return AppTheme.tertiaryContainer }
        if category.contains("考试") { return AppTheme.errorContainer }
        return AppTheme.primaryContainer
    }
}
