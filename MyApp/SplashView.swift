import SwiftUI

// MARK: - SC0 · 스플래시

struct SplashView: View {
    @Environment(AppState.self) private var appState
    @State private var appeared = false

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 24) {
                LogoMark(size: 108)
                    .scaleEffect(appeared ? 1 : 0.8)
                    .opacity(appeared ? 1 : 0)

                VStack(spacing: 8) {
                    Text("Veritae")
                        .font(.system(size: 40, weight: .bold, design: .rounded))

                    Text("진실을 검증하다")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.7)) {
                appeared = true
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.smooth) {
                appState.finishSplash()
            }
        }
    }
}

#Preview {
    SplashView()
        .environment(AppState())
}
