import Foundation
import Observation

/// 인증 상태와 동작을 담당하는 스토어 (ADR-0005). `AppState`가 이를 소유·조합해
/// 환경 주입 지점을 하나로 유지한다 — `AuthStore`를 별도로 `.environment()`하지 않는다.
///
/// `phase`(화면 전환)는 여기서 다루지 않는다 — 이 타입은 결과(`member`, 던지는 오류,
/// `AuthSession.RestoreResult`)만 반환/발행하고, `phase` 전환은 항상 호출부(View → `AppState`)가
/// 담당한다. 이 경계가 깨지면 ADR-0005가 노린 관심사 분리가 무너진다.
@MainActor
@Observable
final class AuthStore {
    private(set) var member: MemberDTO?

    private let api: AuthAPI
    private let session: AuthSession

    init(api: AuthAPI, tokenStore: TokenStoring = KeychainTokenStore()) {
        self.api = api
        self.session = AuthSession(api: api, tokenStore: tokenStore)
    }

    /// `POST /auth/signup`. 성공해도 자동 로그인하지 않는다 — signup 응답에 토큰이 없고,
    /// 가입 직후 자동 로그인은 하지 않기로 확정했다(PRD 미결 1, 사용자 확정).
    func signUp(email: String, password: String, nickname: String) async throws -> MemberDTO {
        do {
            return try await api.signUp(email: email, password: password, nickname: nickname)
        } catch let apiError as AuthAPIError {
            throw AuthError(apiError: apiError)
        }
    }

    /// `POST /auth/login` → 토큰 저장 → `GET /members/me`로 `member` 확보.
    func signIn(email: String, password: String) async throws {
        do {
            let tokens = try await api.logIn(email: email, password: password)
            try await session.saveInitialTokens(tokens)
            member = try await session.authorizedMe()
        } catch let apiError as AuthAPIError {
            throw AuthError(apiError: apiError)
        } catch is TokenStoreError {
            // M6: Keychain 저장 실패가 raw로 View까지 새 나가면 "일시적인 오류가 발생했습니다"
            // (서버 500과 동일 문구)로 보여 사용자가 서버 문제로 오해한다. 구분되는 문구로 매핑한다.
            throw AuthError.storageFailure
        } catch is AuthSessionError {
            throw AuthError.storageFailure
        }
    }

    /// 인증이 필요한 임의 호출(analysis)의 진입점. `AuthSession`을 외부에 노출하지 않아
    /// 토큰 보유·갱신 책임이 이 타입 안에 남는다(ADR-0005).
    ///
    /// **오류를 `AuthError`로 매핑하지 않고 그대로 던진다.** 호출자(`AnalysisStore`)는 자기
    /// 도메인 오류(`AnalysisError`)로 변환해야 하는데, 여기서 한 번 `AuthError`로 뭉개면
    /// `INVALID_IMAGE_FILE` 같은 analysis 고유 코드가 "알 수 없는 오류"로 사라진다.
    /// 401 계열은 `AuthSession`이 이미 refresh + 1회 재시도까지 마친 뒤 전파한 것이다(AC-11).
    func withValidAccessToken<T: Sendable>(
        _ body: @Sendable (String) async throws -> T
    ) async throws -> T {
        try await session.withValidAccessToken(body)
    }

    /// 스플래시 세션 복원 (ADR-0008). `member`는 성공 시에만 갱신한다.
    func restoreSession() async -> AuthSession.RestoreResult {
        let result = await session.restoreSession()
        if case .restored(let restoredMember) = result {
            member = restoredMember
        }
        return result
    }

    /// 클라이언트 전용 로그아웃 — 서버 호출 없음(ADR-0002). Keychain 토큰 삭제 + 인메모리 정리.
    func signOut() async {
        await session.clearTokens()
        member = nil
    }

    #if DEBUG
    /// DEBUG 전용 화면 토글에서 서버 호출 없이 로그인된 화면을 흉내 낼 때만 쓴다(사용자 요청).
    /// Release 빌드에서는 `#if DEBUG`로 완전히 제외된다.
    func debugSetMember(_ member: MemberDTO) {
        self.member = member
    }
    #endif
}
