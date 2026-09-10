#if DEBUG
import SwiftUI

/// DEBUG 전용 — 서버 없이 화면을 오가고 목/실서버 모드를 전환하는 오버레이(사용자 명시 요청).
/// `#if DEBUG`로 감싸여 Release 빌드에는 절대 포함되지 않는다.
///
/// 목 모드 전환이 여기 있는 이유: 런치 인자(`-UseMockAuthAPI 1`)를 바꾸려면 Xcode 스킴을
/// 고치고 재실행해야 하는데, 서버가 미배포인 동안은 목/실서버를 자주 왕복하게 된다.
///
/// **모드를 바꿀 때 저장된 토큰을 반드시 지운다.** 목 토큰은 실서버에서 절대 성공할 수 없는데
/// Keychain 에 남아 다음 실행의 세션 복원을 "네트워크에 연결할 수 없습니다"로 떨어뜨린다
/// (시뮬레이터 Keychain 은 앱을 삭제해도 지워지지 않아 앱 안에 탈출 수단이 없으면 갇힌다 — 실측).
struct DebugModeSwitcher: View {
    @Environment(AppState.self) private var appState
    @State private var isExpanded = false
    @State private var isMockMode = AppConfig.isMockModeEnabled
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isExpanded {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(isMockMode ? "목 모드" : "실서버 모드")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isMockMode ? .orange : .green)

                    debugButton(isMockMode ? "실서버 모드로" : "목 모드로") {
                        Task { await switchMode(toMock: !isMockMode) }
                    }

                    // 목 모드에서만 의미가 있다 — 실서버 모드에서 누르면 실제 서버로 로그인을
                    // 시도해 실패한다. 목 로그인은 정상 경로(`AuthStore.signIn`)를 그대로 타서
                    // Keychain 에 진짜 토큰을 남기므로, 그 뒤 분석 같은 인증 필요 기능이 동작한다.
                    if isMockMode {
                        debugButton("목 계정 로그인") {
                            Task { await mockSignIn() }
                        }
                    }

                    Divider().frame(width: 120)

                    // "회원가입 화면" 버튼은 제거했다 — `fullScreenCover`로 띄웠더니 닫는 수단이
                    // 없어 갇혔다. 회원가입은 로그인 화면의 "회원가입" 링크로 정상 진입하면 되고,
                    // 그 경로가 실제 사용자 흐름이기도 하다.
                    debugButton("로그인 화면") {
                        withAnimation(.smooth) { appState.phase = .login }
                    }
                    // 화면만 흉내 낸다 — 토큰이 없으므로 이 상태에서 분석을 누르면
                    // "세션이 만료되었습니다"가 정상이다. 분석까지 시험하려면 "목 계정 로그인".
                    debugButton("로그인된 화면 (화면만)") {
                        appState.authStore.debugSetMember(Self.debugMember)
                        withAnimation(.smooth) { appState.phase = .main }
                    }

                    debugButton("토큰 초기화") {
                        Task { await clearTokens() }
                    }
                }
                .disabled(isWorking)
                .padding(10)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("디버그 화면 전환")
        }
        .padding(16)
        // M7: 이 뷰가 붙는 `ZStack`(ContentView)의 기본 정렬은 `.center`다. 이 VStack의
        // `alignment: .trailing`은 **자기 자식들끼리의** 정렬일 뿐, ZStack 안에서 이 뷰 자체의
        // 위치는 정해주지 않는다 — 그래서 화면 정중앙에 떠서 컨텐츠를 가리고 탭을 가로챘다.
        // `.infinity` 프레임 + `.bottomTrailing`으로 이 뷰 스스로 화면 우하단에 붙인다.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private static let debugMember = MemberDTO(id: "debug-id", email: "debug@veritae.app", nickname: "디버그")

    // MARK: - 동작

    private func switchMode(toMock: Bool) async {
        isWorking = true
        defer { isWorking = false }

        // 순서가 중요하다 — **모드를 바꾸기 전에** 지금 모드의 토큰을 지운다. 먼저 모드를
        // 바꾸면 `signOut()` 이 새 모드 기준으로 동작해 남은 토큰을 놓칠 수 있다.
        await appState.authStore.debugClearTokens()
        AppConfig.isMockModeEnabled = toMock
        isMockMode = toMock
        appState.records.removeAll()
        withAnimation(.smooth) { appState.phase = .login }
    }

    private func mockSignIn() async {
        isWorking = true
        defer { isWorking = false }
        do {
            // MockAuthAPI 는 자격 증명을 검증하지 않는다 — 형식만 맞으면 통과한다.
            try await appState.authStore.signIn(email: "debug@veritae.app", password: "veritae123")
            withAnimation(.smooth) { appState.phase = .main }
        } catch {
            print("[Veritae][Debug] 목 로그인 실패 — \(error). 목 모드가 켜져 있는지 확인.")
        }
    }

    private func clearTokens() async {
        isWorking = true
        defer { isWorking = false }
        await appState.authStore.debugClearTokens()
        appState.records.removeAll()
        withAnimation(.smooth) { appState.phase = .login }
    }

    private func debugButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .buttonStyle(.glass)
    }
}
#endif
