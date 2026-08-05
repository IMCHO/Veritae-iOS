#if DEBUG
import SwiftUI

/// DEBUG 전용 — 서버 없이 회원가입/로그인/로그인된 화면 세 가지를 즉시 오가며 눈으로 확인하기
/// 위한 오버레이(사용자 명시 요청). `#if DEBUG`로 감싸여 Release 빌드에는 절대 포함되지 않는다.
///
/// 목 API(`-UseMockAuthAPI 1`)와 함께 동작한다 — 이 스위처 자체는 네트워크를 호출하지 않고
/// 화면만 전환하므로 실서버/목 어느 쪽이 붙어 있어도 안전하다. "로그인된 화면" 토글만
/// `AuthStore.debugSetMember(_:)`로 목 member 데이터를 주입한다(요청 사항 그대로).
struct DebugAuthSwitcher: View {
    @Environment(AppState.self) private var appState
    @State private var isExpanded = false

    private static let debugMember = MemberDTO(id: "debug-id", email: "debug@veritae.app", nickname: "디버그")

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isExpanded {
                VStack(alignment: .trailing, spacing: 6) {
                    // "회원가입 화면" 버튼은 제거했다 — `fullScreenCover`로 띄웠더니 닫는 수단이
                    // 없어 갇혔다. 회원가입은 로그인 화면의 "회원가입" 링크로 정상 진입하면 되고,
                    // 그 경로가 실제 사용자 흐름이기도 하다.
                    debugButton("로그인 화면") {
                        withAnimation(.smooth) { appState.phase = .login }
                    }
                    debugButton("로그인된 화면") {
                        appState.authStore.debugSetMember(Self.debugMember)
                        withAnimation(.smooth) { appState.phase = .main }
                    }
                }
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

    private func debugButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption.weight(.semibold))
            .buttonStyle(.glass)
    }
}
#endif
