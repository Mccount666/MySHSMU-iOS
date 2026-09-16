import SwiftUI

extension Color {
    /// Builds a colour from a packed `0xRRGGBB` literal, the notation the
    /// Kotlin theme and palette use.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Palette from `ui/theme/Color.kt`.
///
/// Android prefers Material You's wallpaper-derived scheme when the device
/// supports it and falls back to these fixed colours otherwise; iOS has no
/// equivalent system source, so the fixed scheme is always used. The tint
/// adapts to dark mode the same way the Android fallback does.
enum AppTheme {
    static let purple40 = Color(hex: 0x6650A4)
    static let purpleGrey40 = Color(hex: 0x625B71)
    static let pink40 = Color(hex: 0x7D5260)

    static let purple80 = Color(hex: 0xD0BCFF)
    static let purpleGrey80 = Color(hex: 0xCCC2DC)
    static let pink80 = Color(hex: 0xEFB8C8)

    static var accent: Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? 0xD0BCFF : 0x6650A4)
        })
    }

    static var secondaryAccent: Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? 0xCCC2DC : 0x625B71)
        })
    }

    /// Course blocks sit on pastel fills, so their text stays dark in both
    /// colour schemes — matching the hard-coded `Color.Black` alphas in
    /// `CurriculumScreen.kt`.
    static let onCourseBlock = Color.black.opacity(0.8)
    static let onCourseBlockSecondary = Color.black.opacity(0.6)

    // MARK: - Container colours for the classroom timeline
    //
    // Material 3's light/dark container roles that the Kotlin screen picks
    // between for self-study, exams and ordinary lessons.

    /// Ordinary lesson.
    static var primaryContainer: Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? 0x4F378B : 0xEADDFF)
        })
    }

    /// Self-study period (`ctypeId2` contains 自习).
    static var tertiaryContainer: Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? 0x633B48 : 0xFFD8E4)
        })
    }

    /// Exam (`ctypeId2` contains 考试).
    static var errorContainer: Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? 0x8C1D18 : 0xF9DEDC)
        })
    }

    // MARK: - Metrics shared by the timetable and classroom grids

    static let timeColumnWidth: CGFloat = 40
    static let gridHeaderHeight: CGFloat = 50
    static let gridHorizontalPadding: CGFloat = 8
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Applies the tint and accent colours to a view tree.
struct AppThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(AppTheme.accent)
    }
}

extension View {
    func appTheme() -> some View {
        modifier(AppThemeModifier())
    }
}
