import Foundation

// MARK: - 요청 DTO (Encodable) — `api/openapi.yaml` 스키마와 1:1, CodingKeys 불필요 (camelCase 동일)
//
// M1 후속: 이 파일의 모든 타입에 `nonisolated`를 붙인다. 프로젝트가
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`라 무표기 타입은 **선언 자체**뿐 아니라
// `Encodable`/`Decodable` **conformance**까지 MainActor로 격리 추론된다(실측 확인,
// `xcrun swiftc -typecheck -swift-version 5 -default-isolation MainActor`). 그 상태로
// `nonisolated`로 표시한 `LiveAuthAPI`(M1)의 메서드 안에서 `JSONEncoder.encode`/
// `JSONDecoder.decode`에 넘기면 "conformance ... cannot be used in nonisolated context"
// 경고가 뜬다(Swift 6에서는 오류). DTO 자체를 nonisolated로 선언해 원천 차단한다.

nonisolated struct SignUpRequestBody: Encodable, Sendable {
    let email: String
    let password: String
    let nickname: String
}

nonisolated struct LoginRequestBody: Encodable, Sendable {
    let email: String
    let password: String
}

nonisolated struct RefreshRequestBody: Encodable, Sendable {
    let refreshToken: String
}

// MARK: - 성공 응답 DTO (Decodable)

/// `POST /auth/signup`(201)과 `GET /members/me`(200)가 공유하는 스키마 (`MemberResponse`).
nonisolated struct MemberDTO: Decodable, Sendable {
    let id: String
    let email: String
    let nickname: String
}

/// `POST /auth/login`(200). accessToken + refreshToken을 함께 담는다.
nonisolated struct TokenPairDTO: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
}

/// `POST /auth/refresh`(200). **refreshToken을 포함하지 않는다** — 회전하지 않으므로
/// `TokenPairDTO`와 의도적으로 다른 타입이다 (ADR-0010). 이 타입에 refreshToken 프로퍼티가
/// 없으므로 저장된 refreshToken을 실수로 덮어쓰는 것이 컴파일 단계에서 불가능하다.
nonisolated struct AccessTokenDTO: Decodable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
}

// MARK: - 오류 스키마 (RFC 9457, `ProblemDetail`)

/// 모든 4xx/5xx 오류가 공유하는 단일 스키마.
///
/// - `status`/`errorCode` 모두 옵셔널이다. `api/openapi.yaml`의 애플리케이션 레벨 계약은
///   `errorCode`를 required로 두지만(ADR-0011), Spring Boot가 커스텀 `@RestControllerAdvice`를
///   타지 않는 오류(본문 JSON 파싱 실패 400 / 405 / 415 / 406)에는 이 확장 멤버가 실리지 않는다
///   (`api/CHANGES-2026-08-05.md` §3.2.1). non-optional로 구현하면 그 응답들에서
///   `ProblemDetail` 디코딩 자체가 실패해 "알 수 없는 오류"로 떨어진다 — 두 필드 모두
///   옵셔널로 두고 HTTP 상태코드(응답 자체의 status, 이 값이 아니라)로 폴백한다.
/// - `errorCode`는 절대 Swift `enum`으로 디코딩하지 않는다 — 서버가 새 코드를 추가하면
///   enum 디코딩은 오류 본문 전체를 폴백으로 떨어뜨린다(ADR-0011, SAFE 변경 조건).
///   알려진 6종 매핑은 `KnownErrorCode(rawValue:)`로 디코딩 이후 별도로 조회한다.
nonisolated struct ProblemDetail: Decodable, Sendable {
    nonisolated struct Violation: Decodable, Sendable {
        let field: String
        let message: String
    }

    let type: String?
    let title: String?
    let status: Int?
    let detail: String?
    let instance: String?
    let errorCode: String?
    let timestamp: String?
    let violations: [Violation]?
}

/// `ProblemDetail.errorCode`로 알려진 6종 — 디코딩 타입이 아니라 매핑 조회 전용.
enum KnownErrorCode: String {
    case validationFailed = "VALIDATION_FAILED"
    case invalidCredentials = "INVALID_CREDENTIALS"
    case invalidRefreshToken = "INVALID_REFRESH_TOKEN"
    case unauthorized = "UNAUTHORIZED"
    case emailAlreadyExists = "EMAIL_ALREADY_EXISTS"
    case internalServerError = "INTERNAL_SERVER_ERROR"
}

/// 네트워크 계층에서 던지는 오류. UI 레이어는 이 타입을 직접 보지 않고 `AuthError`로 변환된 것을 본다.
enum AuthAPIError: Error, Sendable {
    /// 서버가 `application/problem+json`을 준 경우. `status`는 응답의 실제 HTTP 상태코드
    /// (본문 `ProblemDetail.status`가 아니다 — 그 값은 참고용일 뿐 분기에 쓰지 않는다).
    case problem(ProblemDetail, status: Int)
    /// 4xx/5xx인데 `problem+json`으로 디코딩되지 않음 (게이트웨이 HTML 등, PRD E9).
    case http(status: Int)
    /// 오프라인·타임아웃 등 전송 계층 실패 (PRD E7).
    case transport(URLError)
    /// 2xx인데 성공 스키마와 어긋남.
    case decoding(Error)
}

// MARK: - AuthAPI 프로토콜 (목/실 구현 교체 지점, ADR-0001)

/// `nonisolated` — 이 프로토콜은 `AuthSession` actor에서 호출된다. 프로젝트가
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`라 명시하지 않으면 요구사항 전체가 MainActor로
/// 격리 추론되고, 그러면 `JSONEncoder`/`JSONDecoder`/`JSONSerialization` 작업이 메인 스레드에서
/// 실행돼 actor로 오프로딩한 의미가 사라진다(M1, LL-002). 구현체(`LiveAuthAPI`/`MockAuthAPI`)의
/// 멤버에도 반드시 짝을 맞춰 `nonisolated`를 붙여야 한다 — 한쪽만 붙이면 Swift 6에서
/// conformance isolation 오류가 난다.
protocol AuthAPI: Sendable {
    nonisolated func signUp(email: String, password: String, nickname: String) async throws -> MemberDTO
    nonisolated func logIn(email: String, password: String) async throws -> TokenPairDTO
    /// refreshToken 반환 안 함 — 회전하지 않는다(ADR-0010).
    nonisolated func refresh(refreshToken: String) async throws -> AccessTokenDTO
    nonisolated func me(accessToken: String) async throws -> MemberDTO
}
