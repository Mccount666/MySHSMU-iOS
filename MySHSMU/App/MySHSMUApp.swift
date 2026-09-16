import SwiftUI

@main
struct MySHSMUApp: App {
    /// Owned by the app so the single instance survives view updates.
    @State private var viewModel = MainViewModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(viewModel)
                .appTheme()
        }
    }
}
