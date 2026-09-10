import Foundation

/// `URLSession` 호출과 응답 해석을 auth·analysis가 공유하는 지점.
///
/// `LiveAuthAPI`가 갖고 있던 private 헬퍼를 그대로 옮긴 것이다. 복제하지 않고 공용으로 두는
/// 이유는 **errorCode 폴백 규칙이 두 경로에서 반드시 같아야** 하기 때문이다 — 한쪽만 고치면
/// "auth에서는 서버 detail이 뜨는데 analysis에서는 '알 수 없는 오류'가 뜬다" 같은 갈림이 생기고,
/// 그건 재현 조건이 서버 응답에 달려 있어 손으로 잡기 어렵다.
///
/// `nonisolated` — 직렬화·디코딩이 메인 스레드로 새지 않게 한다(LL-002).
nonisolated enum HTTPTransport {

    /// 요청을 보내고 `HTTPURLResponse`를 보장한다.
    static func send(_ request: URLRequest, using urlSession: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthAPIError.transport(URLError(.badServerResponse))
            }
            return (data, httpResponse)
        } catch let error as AuthAPIError {
            throw error
        } catch let error as URLError {
            // LL-001: 취소는 `URLError(.cancelled)`로 온다 — `CancellationError`가 아니다.
            // `.transport`로 뭉뚱그리면 화면을 이탈했을 뿐인데 가짜 오프라인 문구가 뜬다.
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw AuthAPIError.transport(error)
        } catch {
            throw AuthAPIError.transport(URLError(.unknown))
        }
    }

    /// 2xx면 본문을 디코딩하고, 그 외에는 `problem+json` → 상태코드 폴백 순으로 오류를 만든다.
    static func decodeSuccess<T: Decodable>(
        _ type: T.Type,
        data: Data,
        response: HTTPURLResponse
    ) throws -> T {
        try ensureSuccess(data: data, response: response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AuthAPIError.decoding(error)
        }
    }

    /// 본문을 디코딩하지 않고 상태코드만 검증한다.
    static func ensureSuccess(data: Data, response: HTTPURLResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw errorFor(data: data, status: response.statusCode)
        }
    }

    /// 4xx/5xx 응답을 `problem+json`으로 우선 해석하고, 실패하면 상태코드 기반 폴백으로 떨어진다
    /// (게이트웨이가 HTML 등 계약 밖 본문을 줘도 크래시하지 않는다).
    ///
    /// `ProblemDetail`은 전 필드가 옵셔널이라 `{}`나 임의 JSON도 "성공적으로" 디코딩된다.
    /// errorCode/status가 둘 다 없으면 우리 계약과 무관한 본문이었을 가능성이 높으므로
    /// `.http`로 내려 상태코드 폴백을 태운다.
    static func errorFor(data: Data, status: Int) -> AuthAPIError {
        if let problem = try? JSONDecoder().decode(ProblemDetail.self, from: data),
           problem.errorCode != nil || problem.status != nil {
            return .problem(problem, status: status)
        }
        return .http(status: status)
    }
}
