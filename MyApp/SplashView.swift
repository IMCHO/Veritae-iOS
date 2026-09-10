import SwiftUI

// MARK: - SC0 · 스플래시

struct SplashView: View {
    @Environment(AppState.self) private var appState
    @State private var appeared = false
    @State private var restoreError: AuthError?
    @State private var isRetrying = false
    @State private var retryTask: Task<Void, Never>?

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

                // 세션 복원이 401이 아닌 오류(오프라인·타임아웃)로 실패한 경우 —
                // 토큰은 삭제하지 않고 재시도 UI를 보여준다. `.login`으로 보내지 않는다(E11, 사용자 확정).
                if let restoreError {
                    VStack(spacing: 12) {
                        Text(restoreError.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            retry()
                        } label: {
                            if isRetrying {
                                ProgressView()
                            } else {
                                Text("다시 시도")
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(isRetrying)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.7)) {
                appeared = true
            }
        }
        .task {
            await restore()
        }
        .onDisappear {
            // M4: 수동으로 만든 `retryTask`는 `.task {}`와 달리 뷰 생명주기에 자동으로
            // 묶이지 않는다 — 명시적으로 취소한다.
            retryTask?.cancel()
        }
    }

    /// 최소 표시 1.6초와 세션 복원 완료 중 늦은 쪽에서 전환한다(ADR-0008).
    private func restore() async {
        // M4: 여기서 `restoreError = nil`을 먼저 하지 않는다. 예전에는 재시도 시작과 동시에
        // `if let restoreError` 블록 전체가 언마운트돼(ProgressView·`.disabled(isRetrying)` 포함)
        // 최소 1.6초 동안 아무 피드백 없는 화면이 됐다. 이전 오류 메시지를 그대로 보여준 채
        // 버튼만 스피너로 바뀌었다가, 결과가 나오면 그때 교체한다.
        async let minimumDisplay: Void? = try? Task.sleep(for: .seconds(1.6))
        let result = await appState.authStore.restoreSession()
        _ = await minimumDisplay

        guard !Task.isCancelled else { return }

        switch result {
        case .restored:
            withAnimation(.smooth) { appState.phase = .main }
        case .loggedOut:
            withAnimation(.smooth) { appState.phase = .login }
        case .failed(let apiError):
            withAnimation(.smooth) { restoreError = AuthError(apiError: apiError) }
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        retryTask = Task {
            await restore()
            isRetrying = false
        }
    }
}

#if DEBUG
// M8: `MockAuthAPI`/`InMemoryTokenStore`는 DEBUG 전용이라 프리뷰도 맞춰 감싼다
// (실측: 없이 했다가 Release 빌드가 "cannot find 'MockAuthAPI' in scope"로 실패했다).
#Preview {
    SplashView()
        .environment(AppState(authStore: AuthStore(api: MockAuthAPI(), tokenStore: InMemoryTokenStore()), analysisAPI: MockAnalysisAPI()))
}
#endif
