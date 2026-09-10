import Foundation

#if DEBUG

/// `api/openapi.yaml` 명세대로 동작하는 목 구현. 서버 미배포 상태에서 개발/QA를 진행하기 위함
/// (ADR-0001, PRD iOS-4). `-UseMockAuthAPI 1` 런치 인자로 전환하고, `-MockAuthScenario <case>`로
/// 오류 케이스를 재현한다 (PRD E15).
///
/// **DEBUG 전용이다.** 이 타입은 자격 증명 검증 없이 토큰을 발급하므로 Release 바이너리에
/// 실려서는 안 된다 — 런치 인자/UserDefaults 로 전환되는 구조라 Release 에 남으면
/// 인증 우회 경로가 된다. 파일 전체를 `#if DEBUG` 로 감싼 이유다.
struct MockAuthAPI: AuthAPI {
    enum Scenario: String, Sendable {
        /// 회원가입 409 EMAIL_ALREADY_EXISTS
        case emailTaken
        /// 회원가입 400 VALIDATION_FAILED + violations
        case validationFailed
        /// 로그인 401 INVALID_CREDENTIALS
        case invalidCredentials
        /// refresh 401 INVALID_REFRESH_TOKEN
        case invalidRefreshToken
        /// members/me 401 UNAUTHORIZED (매번 — refresh도 계속 실패해 AC-11 재현용)
        case unauthorized
        /// 모든 호출 500 INTERNAL_SERVER_ERROR
        case serverError
    }

    let scenario: Scenario?

    init(scenario: Scenario? = nil) {
        self.scenario = scenario
    }

    nonisolated func signUp(email: String, password: String, nickname: String) async throws -> MemberDTO {
        try await Task.sleep(for: .milliseconds(400))
        if scenario == .serverError {
            throw Self.serverError(instance: "/api/v1/auth/signup")
        }
        if scenario == .emailTaken || email.lowercased().hasPrefix("taken") {
            throw Self.problem(
                status: 409,
                errorCode: KnownErrorCode.emailAlreadyExists.rawValue,
                title: "Email Already Exists",
                detail: "이미 가입된 이메일입니다.",
                instance: "/api/v1/auth/signup"
            )
        }
        if scenario == .validationFailed {
            throw Self.problem(
                status: 400,
                errorCode: KnownErrorCode.validationFailed.rawValue,
                title: "Validation Failed",
                detail: "요청 값 검증에 실패했습니다.",
                instance: "/api/v1/auth/signup",
                violations: [
                    ProblemDetail.Violation(
                        field: "password",
                        message: "8~20자, 영문자와 숫자를 각각 1자 이상 포함해야 합니다."
                    ),
                ]
            )
        }
        return MemberDTO(id: UUID().uuidString, email: email, nickname: nickname)
    }

    nonisolated func logIn(email: String, password: String) async throws -> TokenPairDTO {
        try await Task.sleep(for: .milliseconds(500))
        if scenario == .serverError {
            throw Self.serverError(instance: "/api/v1/auth/login")
        }
        if scenario == .invalidCredentials {
            throw Self.problem(
                status: 401,
                errorCode: KnownErrorCode.invalidCredentials.rawValue,
                title: "Invalid Credentials",
                detail: "이메일 또는 비밀번호가 일치하지 않습니다.",
                instance: "/api/v1/auth/login"
            )
        }
        return TokenPairDTO(
            accessToken: "mock-access-\(UUID().uuidString)",
            refreshToken: "mock-refresh-\(UUID().uuidString)",
            tokenType: "Bearer",
            expiresIn: 1800
        )
    }

    nonisolated func refresh(refreshToken: String) async throws -> AccessTokenDTO {
        try await Task.sleep(for: .milliseconds(300))
        if scenario == .serverError {
            throw Self.serverError(instance: "/api/v1/auth/refresh")
        }
        if scenario == .invalidRefreshToken {
            throw Self.problem(
                status: 401,
                errorCode: KnownErrorCode.invalidRefreshToken.rawValue,
                title: "Invalid Refresh Token",
                detail: "리프레시 토큰이 유효하지 않습니다.",
                instance: "/api/v1/auth/refresh"
            )
        }
        // 명세: refresh 응답은 refreshToken을 포함하지 않는다 (ADR-0010).
        return AccessTokenDTO(accessToken: "mock-access-\(UUID().uuidString)", tokenType: "Bearer", expiresIn: 1800)
    }

    nonisolated func me(accessToken: String) async throws -> MemberDTO {
        try await Task.sleep(for: .milliseconds(300))
        if scenario == .serverError {
            throw Self.serverError(instance: "/api/v1/members/me")
        }
        if scenario == .unauthorized {
            throw Self.problem(
                status: 401,
                errorCode: KnownErrorCode.unauthorized.rawValue,
                title: "Unauthorized",
                detail: "액세스 토큰이 유효하지 않습니다.",
                instance: "/api/v1/members/me"
            )
        }
        return MemberDTO(id: "mock-member-id", email: "user@veritae.app", nickname: "진실이")
    }

    // MARK: - problem+json 조립 (명세 §5.2 그대로)

    private nonisolated static func problem(
        status: Int,
        errorCode: String,
        title: String,
        detail: String,
        instance: String,
        violations: [ProblemDetail.Violation]? = nil
    ) -> AuthAPIError {
        let problemDetail = ProblemDetail(
            type: "https://api.veritae.app/errors/\(errorCode.lowercased())",
            title: title,
            status: status,
            detail: detail,
            instance: instance,
            errorCode: errorCode,
            timestamp: ISO8601DateFormatter().string(from: .now),
            violations: violations
        )
        return .problem(problemDetail, status: status)
    }

    private nonisolated static func serverError(instance: String) -> AuthAPIError {
        problem(
            status: 500,
            errorCode: KnownErrorCode.internalServerError.rawValue,
            title: "Internal Server Error",
            detail: "일시적인 오류가 발생했습니다.",
            instance: instance
        )
    }
}

#endif
