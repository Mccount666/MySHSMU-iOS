import SwiftUI

/// Port of `ui/AppContent.kt` and `MainActivity.kt`: the login screen flips to
/// the main tabs once a session exists, with the status banner layered on top.
struct AppRootView: View {
    @Environment(MainViewModel.self) private var viewModel

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if viewModel.state.isLoggedIn {
                    MainTabView()
                        .transition(.opacity)
                } else {
                    LoginView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: viewModel.state.isLoggedIn)

            NotificationBanner(state: viewModel.state.notificationState)
        }
    }
}
