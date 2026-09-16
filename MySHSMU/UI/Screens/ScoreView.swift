import SwiftUI

/// Port of `ui/screens/ScoreScreen.kt`.
///
/// Column widths follow the Kotlin weights (课程 3, 学分 1, 分数 1.5, 评级 1)
/// scaled to the available width.
struct ScoreView: View {
    @Environment(MainViewModel.self) private var viewModel

    private static let weights: [CGFloat] = [3, 1, 1.5, 1]

    private var state: MySHSMUUiState { viewModel.state }

    var body: some View {
        GeometryReader { geometry in
            let available = max(geometry.size.width - 32, 1)
            let totalWeight = Self.weights.reduce(0, +)
            let widths = Self.weights.map { available * $0 / totalWeight }

            ZStack {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        PickerField(
                            label: "学年",
                            value: state.selectedYear ?? "选择学年",
                            placeholder: state.selectedYear == nil,
                            options: state.scoreYears,
                            titleFor: { $0 },
                            onSelect: { viewModel.fetchScoreData(year: $0) }
                        )
                        PickerField(
                            label: "学期",
                            value: "第 \(state.selectedSemester) 学期",
                            placeholder: false,
                            options: [1, 2],
                            titleFor: { "第 \($0) 学期" },
                            onSelect: { viewModel.fetchScoreData(semester: $0) }
                        )
                    }
                    .padding(.bottom, 16)

                    if let gpa = state.gpaInfo, !gpa.isEmpty {
                        Text(gpa)
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 8)
                    }

                    HStack(spacing: 0) {
                        headerCell("课程", width: widths[0], alignment: .leading)
                        headerCell("学分", width: widths[1], alignment: .center)
                        headerCell("分数", width: widths[2], alignment: .center)
                        headerCell("评级", width: widths[3], alignment: .center)
                    }
                    .padding(.vertical, 8)

                    Divider()

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(state.scoreList) { score in
                                ScoreRow(score: score, widths: widths)
                                Divider().padding(.horizontal, 4)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)

                if state.isScoreListLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial.opacity(0.5))
                }
            }
        }
    }

    private func headerCell(_ title: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(title)
            .font(.footnote.weight(.bold))
            .foregroundStyle(AppTheme.accent)
            .frame(width: width, alignment: alignment)
    }
}

private struct ScoreRow: View {
    let score: ScoreItem
    let widths: [CGFloat]

    var body: some View {
        HStack(spacing: 0) {
            Text(score.courseName)
                .font(.body)
                .frame(width: widths[0], alignment: .leading)

            Text(formatted(score.credit))
                .font(.body.weight(.semibold))
                .frame(width: widths[1], alignment: .center)

            VStack(spacing: 2) {
                // A resit or exemption shows its label instead of a number.
                Text(score.examSituation != "正常" ? score.examSituation : formatted(score.score))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(score.score < 60 ? Color.red : Color.primary)

                if score.fScore > 0 {
                    Text("补: \(formatted(score.fScore))")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryAccent)
                }
            }
            .frame(width: widths[2], alignment: .center)

            Text(score.achievementGrade)
                .font(.body.weight(.semibold))
                .frame(width: widths[3], alignment: .center)
        }
        .padding(.vertical, 16)
    }

    /// Drops the trailing `.0` that Kotlin's `Double.toString()` also omits for
    /// whole numbers.
    private func formatted(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }
}

/// Menu-styled field standing in for `ExposedDropdownMenuBox`.
struct PickerField<Option: Hashable>: View {
    let label: String
    let value: String
    let placeholder: Bool
    let options: [Option]
    let titleFor: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(titleFor(option)) { onSelect(option) }
            }
        } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(placeholder ? .secondary : .primary)
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
        }
        .disabled(options.isEmpty)
    }
}
