import SwiftUI

/// The four top-level destinations, replacing the
/// `NavigationSuiteScaffold` in `ui/screens/MainScreen.kt`.
struct MainTabView: View {
    @Environment(MainViewModel.self) private var viewModel

    /// Survives navigation but not a relaunch, matching `rememberSaveable`.
    @SceneStorage("selectedTab") private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            CurriculumView()
                .tabItem { Label("课程", systemImage: "calendar") }
                .tag(0)

            ClassroomView()
                .tabItem { Label("教室", systemImage: "building.2") }
                .tag(1)

            ScoreView()
                .tabItem { Label("成绩", systemImage: "star") }
                .tag(2)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(3)
        }
        .onAppear(perform: applyScreenshotTab)
    }

    /// Screenshot runs open a specific tab via `-uiDemoTab <n>`.
    private func applyScreenshotTab() {
        #if DEBUG
        if let tab = DemoMode.tab { selectedTab = tab }
        #endif
    }
}
