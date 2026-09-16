import SwiftUI

/// Transient status banner, ported from `ui/components/LoadingNotification.kt`.
///
/// Slides in from the top and sits above every screen. Non-loading states are
/// dismissed after three seconds by `MainViewModel`; a loading state stays until
/// the work it describes reports back.
struct NotificationBanner: View {
    let state: NotificationState

    var body: some View {
        VStack(spacing: 0) {
            if state.isVisible {
                content
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.isVisible)
        .animation(.easeInOut(duration: 0.2), value: state.message)
        // The banner is informational; taps belong to the screen beneath it.
        .allowsHitTesting(false)
    }

    private var content: some View {
        HStack(spacing: 12) {
            statusIcon
            Text(state.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state.status {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.accent)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
