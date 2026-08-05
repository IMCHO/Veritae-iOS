import Foundation

/// UI 레이어가 보는 인증 오류. `AuthAPIError`(네트워크 레이어)를 서버 `errorCode` 기반으로
/// 재정의한다(ADR-0005). Raw network error가 View까지 흘러가지 않는다.
enum AuthError: LocalizedError, Sendable {
    /// 로그인 401 INVALID_CREDENTIALS — 이메일/비밀번호 중 어느 쪽이 틀렸는지 구분하지 않는다(명세 명시, E1).
    case invalidCredentials
    /// 가입 409 EMAIL_ALREADY_EXISTS
    case emailAlreadyExists
    /// 400 VALIDATION_FAILED — 필드별 메시지를 그대로 노출한다(E3, ADR-0003/0004: 재작성 금지).
    /// `detail`은 `violations`가 비어 있거나 없을 때(M3)의 전역 오류 폴백 문구로 쓰인다.
    case validationFailed(violations: [ProblemDetail.Violation], detail: String?)
    /// refresh 실패(INVALID_REFRESH_TOKEN) 또는 재시도 후에도 UNAUTHORIZED — 세션 종료.
    case sessionExpired
    /// 오프라인·타임아웃 (E7).
    case network
    /// 500 INTERNAL_SERVER_ERROR.
    case server
    /// 로컬 저장(Keychain) 실패 — 서버와 무관한 기기 자체의 문제(M6). `TokenStoreError`/
    /// `AuthSessionError`가 여기로 매핑된다. 서버 500과 같은 문구를 쓰면 사용자가 서버 문제로
    /// 오해하므로 구분한다.
    case storageFailure
    /// 그 외 — 알 수 없는 errorCode / status 기반 폴백 (E9/AC-14). 크래시 대신 일반 문구.
    /// M2: 서버 `detail`이 있으면 고정 문구 대신 그 값을 우선 사용한다.
    case unknown(String)

    /// `AuthAPIError` → `AuthError` 매핑. errorCode는 `String`으로만 비교하고, 미지 값은
    /// 상태코드 기반 폴백으로 떨어진다 — enum 디코딩 실패가 아니라 매핑 실패이므로 안전하다.
    init(apiError: AuthAPIError) {
        switch apiError {
        case .problem(let problem, let status):
            if let code = problem.errorCode, let known = KnownErrorCode(rawValue: code) {
                switch known {
                case .validationFailed:
                    self = .validationFailed(violations: problem.violations ?? [], detail: problem.detail)
                case .invalidCredentials:
                    self = .invalidCredentials
                case .invalidRefreshToken:
                    self = .sessionExpired
                case .unauthorized:
                    // authorizedMe가 재시도까지 마친 뒤에도 여전히 UNAUTHORIZED라면 세션 종료로 취급.
                    self = .sessionExpired
                case .emailAlreadyExists:
                    self = .emailAlreadyExists
                case .internalServerError:
                    self = .server
                }
            } else if let detail = problem.detail, !detail.isEmpty {
                // M2: errorCode 부재(프레임워크 레벨 오류)·미지 값이어도 서버가 사람이 읽을 수 있는
                // `detail`을 줬다면 고정 문구보다 그걸 우선한다 — ADR-0011이 느슨한 디코딩의
                // 이득으로 명시한 "본문을 읽어 의미 있는 문구를 낸다"를 실제로 쓴다.
                // (6종 known 코드는 여기 안 온다 — 그 문구들은 의도적으로 서버 detail을 쓰지 않는다.
                // 예: INVALID_CREDENTIALS는 이메일/비밀번호 구분을 안 하기 위해 고정 문구여야 한다.)
                self = .unknown(detail)
            } else {
                // detail도 없음 — 상태코드로 폴백.
                self = Self.statusFallback(status)
            }
        case .http(let status):
            self = Self.statusFallback(status)
        case .transport:
            self = .network
        case .decoding:
            self = .server
        }
    }

    private static func statusFallback(_ status: Int) -> AuthError {
        if (500...599).contains(status) {
            return .server
        }
        return .unknown("요청을 처리할 수 없습니다. 잠시 후 다시 시도해 주세요.")
    }

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "이메일 또는 비밀번호를 확인해 주세요."
        case .emailAlreadyExists: "이미 사용 중인 이메일입니다."
        case .validationFailed(_, let detail): detail ?? "입력값을 확인해 주세요."
        case .sessionExpired: "세션이 만료되었습니다. 다시 로그인해 주세요."
        case .network: "네트워크에 연결할 수 없습니다. 잠시 후 다시 시도해 주세요."
        case .server: "일시적인 오류가 발생했습니다. 잠시 후 다시 시도해 주세요."
        case .storageFailure: "기기 저장소에 접근할 수 없습니다. 기기 보안 설정을 확인해 주세요."
        case .unknown(let message): message
        }
    }
}

// MARK: - 비밀번호 클라 선검증 (ADR-0004, 정정 노트 반영 — 비대칭 적용)

enum PasswordRule {
    static let minLength = 8

    /// submit을 막아야 하는 위반이 있으면 힌트 문구를 반환한다. `nil`이면 통과.
    ///
    /// **20자 초과는 검사하지 않는다** — 실제 상한이 명세보다 길 경우 유효한 비밀번호를
    /// 클라가 막는 회귀가 되기 때문이다(ADR-0004 정정 노트). 하한 미달·문자 종류 누락만 막는다.
    static func submitBlockingHint(for password: String) -> String? {
        if password.count < minLength {
            return "비밀번호는 8자 이상이어야 합니다."
        }
        guard password.contains(where: { $0.isASCII && $0.isLetter }) else {
            return "영문자를 1자 이상 포함해야 합니다."
        }
        guard password.contains(where: { $0.isASCII && $0.isNumber }) else {
            return "숫자를 1자 이상 포함해야 합니다."
        }
        return nil
    }

    static func isValidForSubmit(_ password: String) -> Bool {
        submitBlockingHint(for: password) == nil
    }
}
