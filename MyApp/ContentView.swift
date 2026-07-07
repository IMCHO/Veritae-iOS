import SwiftUI

@main struct MyApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }
}

/// 앱 단계(스플래시 → 로그인 → 메인)에 따라 루트 화면을 전환한다.
struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            switch appState.phase {
            case .splash:
                SplashView()
            case .login:
                LoginFlowView()
                    .transition(.opacity)
            case .main:
                MainView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: appState.phase)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
