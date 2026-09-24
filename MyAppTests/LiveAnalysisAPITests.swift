import Foundation
import Testing

@testable import MyApp

/// 요청을 가로채 기록하고 정해 둔 응답을 돌려준다. 실제 네트워크를 타지 않는다.
///
/// 상태가 전역(static)이라 이 파일의 스위트는 `.serialized` 로 돈다. 다른 스위트는 이 프로토콜을 쓰지 않는다.
nonisolated private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `LiveAnalysisAPI` 의 records / report 가 명세대로 요청을 조립하는지(GET · 경로 · Bearer) 확인한다.
/// 스텁 API 로는 이 계층이 전혀 실행되지 않는다.
@Suite("LiveAnalysisAPI 조회 요청", .serialized)
struct LiveAnalysisAPITests {

    private func makeAPI() -> LiveAnalysisAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return LiveAnalysisAPI(baseURL: URL(string: "https://api.example.test")!, urlSession: URLSession(configuration: config))
    }

    @Test("records — GET /api/v1/analysis/records, Bearer, content 를 풀어 준다")
    func recordsRequest() async throws {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("""
        { "content": [ { "id": "a", "modality": "VIDEO", "createdAt": "2026-09-23T08:00:00Z", "errorCode": "NO_FACE_DETECTED" } ] }
        """.utf8)

        let records = try await makeAPI().records(accessToken: "tok")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/analysis/records")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(records.map(\.id) == ["a"])
        #expect(records.first?.videoDetection == nil)
    }

    @Test("report — GET /api/v1/analysis/report, Bearer")
    func reportRequest() async throws {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("""
        { "totalCount": 23, "imageCount": 10, "audioCount": 8, "videoCount": 5, "aiDetectedCount": 3, "scamDetectedCount": 2 }
        """.utf8)

        let report = try await makeAPI().report(accessToken: "tok")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/analysis/report")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(report.scamDetectedCount == 2)
    }

    /// M1: 키 이름이 바뀌거나 항목이 전부 깨진 응답은 `.decoding` 으로 올라와 오류 화면 + 재시도가 된다.
    @Test("records 응답 형태가 통째로 어긋나면 decoding 오류로 올라온다", arguments: [
        #"{ "records": [] }"#,
        #"{ "content": [ { "id": 1, "modality": "IMAGE", "createdAt": "2026-09-23T09:00:00Z" } ] }"#,
    ])
    func recordsMalformedIsDecodingError(json: String) async {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data(json.utf8)

        do {
            _ = try await makeAPI().records(accessToken: "tok")
            Issue.record("형태가 어긋났는데 성공했다")
        } catch AuthAPIError.decoding {
            // 기대한 경로
        } catch {
            Issue.record("기대: AuthAPIError.decoding, 실제: \(error)")
        }
    }

    /// 401 이 `AuthAPIError.problem` 으로 올라와야 `AuthSession` 이 refresh + 재시도를 건다.
    @Test("records 401 은 problem+json 오류로 올라온다")
    func recordsUnauthorized() async {
        StubURLProtocol.status = 401
        StubURLProtocol.body = Data("""
        { "type": "about:blank", "title": "Unauthorized", "status": 401, "errorCode": "UNAUTHORIZED" }
        """.utf8)

        do {
            _ = try await makeAPI().records(accessToken: "expired")
            Issue.record("401 인데 성공했다")
        } catch let AuthAPIError.problem(problem, status) {
            #expect(status == 401)
            #expect(problem.errorCode == "UNAUTHORIZED")
        } catch {
            Issue.record("기대: AuthAPIError.problem, 실제: \(error)")
        }
    }
}
