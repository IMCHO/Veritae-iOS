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

            #if DEBUG
            DebugAuthSwitcher()
            #endif
        }
        .animation(.smooth, value: appState.phase)
    }
}

#if DEBUG
// M8: `MockAuthAPI`/`InMemoryTokenStore`는 DEBUG 전용이라 프리뷰도 맞춰 감싼다
// (실측: 없이 했다가 Release 빌드가 "cannot find 'MockAuthAPI' in scope"로 실패했다).
#Preview {
    ContentView()
        .environment(AppState(authStore: AuthStore(api: MockAuthAPI(), tokenStore: InMemoryTokenStore()), analysisAPI: MockAnalysisAPI()))
}
#endif
