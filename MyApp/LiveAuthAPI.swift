import Foundation

/// 실서버 `AuthAPI` 구현. `URLSession` + async/await. (PRD iOS-3)
struct LiveAuthAPI: AuthAPI {
    let baseURL: URL
    let urlSession: URLSession

    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    nonisolated func signUp(email: String, password: String, nickname: String) async throws -> MemberDTO {
        let body = SignUpRequestBody(email: email, password: password, nickname: nickname)
        let (data, response) = try await execute(path: "/api/v1/auth/signup", body: body, accessToken: nil)
        return try Self.decodeSuccess(MemberDTO.self, data: data, response: response)
    }

    nonisolated func logIn(email: String, password: String) async throws -> TokenPairDTO {
        let body = LoginRequestBody(email: email, password: password)
        let (data, response) = try await execute(path: "/api/v1/auth/login", body: body, accessToken: nil)
        return try Self.decodeSuccess(TokenPairDTO.self, data: data, response: response)
    }

    nonisolated func refresh(refreshToken: String) async throws -> AccessTokenDTO {
        let body = RefreshRequestBody(refreshToken: refreshToken)
        let (data, response) = try await execute(path: "/api/v1/auth/refresh", body: body, accessToken: nil)
        Self.detectUnexpectedRefreshTokenField(in: data, response: response)
        return try Self.decodeSuccess(AccessTokenDTO.self, data: data, response: response)
    }

    nonisolated func me(accessToken: String) async throws -> MemberDTO {
        // `Authorization: Bearer` 헤더는 이 호출에만 붙는다 (PRD iOS-3).
        // 응답의 `tokenType`을 신뢰하지 않고 항상 "Bearer " 리터럴로 조립한다 (ADR-0012).
        let (data, response) = try await executeGet(path: "/api/v1/members/me", accessToken: accessToken)
        return try Self.decodeSuccess(MemberDTO.self, data: data, response: response)
    }

    // MARK: - 요청 실행기

    private nonisolated func execute<Body: Encodable>(
        path: String,
        body: Body,
        accessToken: String?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw AuthAPIError.decoding(error)
        }
        return try await send(request)
    }

    private nonisolated func executeGet(path: String, accessToken: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return try await send(request)
    }

    private nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthAPIError.transport(URLError(.badServerResponse))
            }
            return (data, httpResponse)
        } catch let error as AuthAPIError {
            throw error
        } catch let error as URLError {
            // C2: 취소는 `URLError(.cancelled)`로 온다 — `CancellationError`가 아니다.
            // `.transport`로 뭉뚱그리면 화면을 이탈했을 뿐인데 "네트워크에 연결할 수 없습니다"라는
            // 가짜 오프라인 메시지가 뜬다(E13/TC-IOS-16 위반). 취소는 취소로 전파한다.
            if error.code == .cancelled {
                throw CancellationError()
            }
            // 오프라인·DNS 실패·타임아웃 (PRD E7)
            throw AuthAPIError.transport(error)
        } catch {
            throw AuthAPIError.transport(URLError(.unknown))
        }
    }

    // MARK: - 응답 해석

    private nonisolated static func decodeSuccess<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: HTTPURLResponse
    ) throws -> T {
        guard (200...299).contains(response.statusCode) else {
            throw errorFor(data: data, status: response.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AuthAPIError.decoding(error)
        }
    }

    /// 4xx/5xx 응답을 `problem+json`으로 우선 해석하고, 실패하면 상태코드 기반 폴백으로 떨어진다
    /// (PRD E9/AC-14 — 게이트웨이가 HTML 등 계약 밖 본문을 줘도 크래시하지 않는다).
    private nonisolated static func errorFor(data: Data, status: Int) -> AuthAPIError {
        if let problem = try? JSONDecoder().decode(ProblemDetail.self, from: data),
           problem.errorCode != nil || problem.status != nil {
            // Minor 10: `ProblemDetail`은 전 필드가 옵셔널이라 `{}`나 임의 JSON 오브젝트도
            // "성공적으로" 디코딩된다. errorCode/status가 둘 다 없으면 실제로는 우리 계약과
            // 무관한 본문(E9 대상)이었을 가능성이 높으므로 `.http`로 내려 상태코드 폴백을 태운다.
            return .problem(problem, status: status)
        }
        return .http(status: status)
    }

    /// ADR-0010 정정 노트의 지정 탐지 수단 — refresh 응답에 `refreshToken` 키가 실려 있으면
    /// (계약 위반, 회전 도입 가능성) 로그 + `assertionFailure`를 남긴다.
    /// 프로덕션 동작은 바꾸지 않는다 — 발견해도 accessToken 갱신은 그대로 성공시킨다.
    /// `AccessTokenDTO`에는 애초에 `refreshToken` 프로퍼티가 없어 타입으로는 값을 읽을 수 없으므로,
    /// 원본 JSON을 한 번 더 훑어 키 존재 자체만 확인한다.
    private nonisolated static func detectUnexpectedRefreshTokenField(in data: Data, response: HTTPURLResponse) {
        guard (200...299).contains(response.statusCode) else { return }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["refreshToken"] != nil
        else { return }

        print("[Veritae][Auth] 계약 위반: POST /auth/refresh 응답에 refreshToken 키가 포함되어 있습니다 (ADR-0010).")
        assertionFailure(
            "refresh 응답에 refreshToken 이 포함됨 — ADR-0010 위반. "
            + "회전이 도입된 것이라면 별도 ADR + AuthSession 저장 로직 변경이 필요하다."
        )
    }
}
