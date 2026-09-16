import SwiftUI

/// Port of `ui/screens/LoginScreen.kt`.
struct LoginView: View {
    @Environment(MainViewModel.self) private var viewModel

    @State private var username = ""
    @State private var password = ""
    @State private var didPrefill = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 40)

            Text("登录")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(AppTheme.accent)

            Spacer().frame(height: 40)

            VStack(spacing: 10) {
                TextField("学号", text: $username)
                    .textContentType(.username)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldBackground)

                SecureField("密码", text: $password)
                    .textContentType(.password)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldBackground)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }

            Spacer().frame(height: 40)

            Button(action: submit) {
                HStack(spacing: 8) {
                    if viewModel.state.isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("正在登录...")
                    } else {
                        Text("登录")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.state.isLoggingIn)

            Spacer()

            Text("酱紫办 v\(AppConfig.currentVersionName)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: prefill)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
    }

    /// Fills in the stored credentials so a returning user can log straight
    /// back in, matching the `remember(uiState.savedUsername)` behaviour.
    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        username = viewModel.state.savedUsername
        password = viewModel.state.savedPassword
    }

    private func submit() {
        viewModel.startLogin(user: username, password: password)
    }
}
