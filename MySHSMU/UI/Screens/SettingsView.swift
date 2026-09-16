import SwiftUI

/// Port of `ui/screens/SettingsScreen.kt`.
struct SettingsView: View {
    @Environment(MainViewModel.self) private var viewModel

    @State private var showAbout = false
    @State private var showDatePicker = false
    @State private var showWeekCountDialog = false
    @State private var pickerDate = Date()
    @State private var tempWeekCount = ""
    @State private var tempBlockHeight = 60

    private var state: MySHSMUUiState { viewModel.state }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                Spacer().frame(height: 16)

                Image(systemName: "person.crop.circle")
                    .resizable()
                    .frame(width: 100, height: 100)
                    .foregroundStyle(AppTheme.accent)

                Text(state.savedUsername)
                    .font(.title3.weight(.semibold))

                Button(role: .destructive) {
                    viewModel.logout()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("登出")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                courseSettingsCard

                globalSettingsCard

                Spacer().frame(height: 16)
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showDatePicker) {
            datePickerSheet
        }
        .alert("设置学期周数", isPresented: $showWeekCountDialog) {
            TextField("周数", text: $tempWeekCount)
                .keyboardType(.numberPad)
            Button("确定") {
                if let value = Int(tempWeekCount), value > 0 {
                    viewModel.updateWeekCount(value)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("关于酱紫办", isPresented: $showAbout) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("酱紫办 (MySHSMU) 是一款为上海交通大学医学院学生开发的教务辅助工具。\n\n当前版本: \(AppConfig.currentVersionName)\n开发人员: Reqwey\n\niOS 版本为 Android 版的移植。")
        }
        .alert(
            "发现新版本 v\(state.updateInfo?.version ?? "")",
            isPresented: Binding(
                get: { state.showUpdateDialog && state.updateInfo != nil },
                // A forced update cannot be dismissed by tapping outside.
                set: { newValue in if !newValue { viewModel.dismissUpdateDialog() } }
            )
        ) {
            Button("立即更新") { viewModel.startUpdateDownload() }
            if state.updateInfo?.forceUpdate != true {
                Button("稍后", role: .cancel) { viewModel.dismissUpdateDialog() }
            }
        } message: {
            Text(updateMessage)
        }
        .onAppear(perform: syncLocalState)
    }

    private var updateMessage: String {
        let log = state.updateInfo?.updateLog ?? ""
        return log.isEmpty ? "检测到新版本，建议尽快更新。" : log
    }

    // MARK: - Cards

    private var courseSettingsCard: some View {
        SettingsCard(title: "课程设置") {
            HStack {
                Text("第一周的第一天")
                Spacer()
                Button {
                    if let stored = state.firstWeekStartDate,
                       let date = AppCalendar.date(fromISODate: stored) {
                        pickerDate = date
                    } else {
                        pickerDate = Date()
                    }
                    showDatePicker = true
                } label: {
                    HStack(spacing: 6) {
                        Text(state.firstWeekStartDate ?? "未设置")
                        Image(systemName: "calendar")
                            .font(.caption)
                    }
                }
            }

            HStack {
                Text("学期周数")
                Spacer()
                Button {
                    tempWeekCount = state.weekCount > 0 ? String(state.weekCount) : ""
                    showWeekCountDialog = true
                } label: {
                    HStack(spacing: 6) {
                        Text(state.weekCount > 0 ? "\(state.weekCount) 周" : "未设置")
                        Image(systemName: "square.and.pencil")
                            .font(.caption)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("课程格高")
                Slider(
                    value: Binding(
                        get: { Double(tempBlockHeight) },
                        set: { newValue in
                            // The Kotlin slider snaps to 30 / 45 / 60.
                            let stepped = Int((newValue / 15).rounded()) * 15
                            tempBlockHeight = stepped
                            viewModel.updateCourseBlockHeight(stepped)
                        }
                    ),
                    in: 30...60,
                    step: 15
                )
            }

            Button {
                viewModel.refreshAllData()
            } label: {
                HStack(spacing: 8) {
                    if state.isCourseListLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(state.isCourseListLoading ? "正在刷新..." : "刷新课程信息")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(state.isCourseListLoading)
        }
    }

    private var globalSettingsCard: some View {
        SettingsCard(title: "全局设置") {
            Button {
                viewModel.checkForUpdates(manual: true)
            } label: {
                HStack(spacing: 8) {
                    if state.isCheckingUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(state.updateInfo != nil ? "新版本: v\(state.updateInfo?.version ?? "")" : "检查更新")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(state.isCheckingUpdate)

            Button {
                showAbout = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("关于")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var datePickerSheet: some View {
        NavigationStack {
            VStack {
                DatePicker(
                    "第一周的第一天",
                    selection: $pickerDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal, 16)
                Spacer()
            }
            .navigationTitle("第一周的第一天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showDatePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        // Stored as a plain calendar date; the timetable maths
                        // works on whole days.
                        viewModel.updateFirstWeekStartDate(AppCalendar.isoString(pickerDate))
                        showDatePicker = false
                    }
                }
            }
        }
    }

    private func syncLocalState() {
        tempBlockHeight = state.courseBlockHeight
    }
}

/// Outlined card with a small accent caption, mirroring `OutlinedCard`.
private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.footnote.weight(.bold))
                .foregroundStyle(AppTheme.accent)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        )
    }
}
