import Foundation
import Testing

@testable import MyApp

/// `MultipartBody`는 바이트 단위 결과라 화면으로 검증이 불가능하다 — 경계·CRLF·종료 경계가
/// 하나라도 틀리면 서버가 파트를 못 읽고 400을 낸다. 이 스위트가 유일한 검증 수단이다.
@Suite("MultipartBody")
struct MultipartBodyTests {

    private func makeBody(filename: String = "photo.jpg", payload: Data = Data([0xFF, 0xD8, 0xFF])) -> (MultipartBody, String) {
        var body = MultipartBody(boundary: "TESTBOUNDARY")
        body.appendFile(name: "file", filename: filename, contentType: "image/jpeg", data: payload)
        let text = String(decoding: body.finalized(), as: UTF8.self)
        return (body, text)
    }

    @Test("Content-Type 헤더에 경계가 실린다")
    func contentTypeCarriesBoundary() {
        let body = MultipartBody(boundary: "TESTBOUNDARY")
        #expect(body.contentType == "multipart/form-data; boundary=TESTBOUNDARY")
    }

    @Test("파트가 여는 경계 · Content-Disposition · Content-Type 순서로 조립된다")
    func partStructure() {
        let (_, text) = makeBody()
        #expect(text.hasPrefix("--TESTBOUNDARY\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n"))
        #expect(text.contains("Content-Type: image/jpeg\r\n\r\n"))
    }

    /// 종료 경계가 없으면 서버는 본문이 잘린 것으로 보고 파트를 버린다.
    @Test("종료 경계로 끝난다")
    func terminatingBoundary() {
        let (_, text) = makeBody()
        #expect(text.hasSuffix("--TESTBOUNDARY--\r\n"))
    }

    @Test("본문 바이트가 원본 그대로 실린다")
    func payloadPreserved() throws {
        let payload = Data((0...255).map { UInt8($0) })
        var body = MultipartBody(boundary: "B")
        body.appendFile(name: "file", filename: "blob.bin", contentType: "application/octet-stream", data: payload)
        let finalized = body.finalized()

        // 헤더 뒤 `\r\n\r\n` 다음부터 payload 가 시작한다.
        let separator = Data("\r\n\r\n".utf8)
        let headerEnd = try #require(finalized.range(of: separator))
        let bodyStart = headerEnd.upperBound
        let extracted = finalized[bodyStart..<(bodyStart + payload.count)]
        #expect(Data(extracted) == payload)
    }

    /// 파일 이름은 사용자가 고른 값이라 통제할 수 없다. 큰따옴표는 `filename="..."` 을 조기
    /// 종료시키고, CR/LF 는 헤더를 갈라 임의 헤더를 주입할 수 있다.
    @Test("파일 이름의 큰따옴표와 개행이 제거된다")
    func filenameIsSanitized() {
        let (_, text) = makeBody(filename: "ev\"il\r\nX-Injected: 1.jpg")
        #expect(text.contains("filename=\"evilX-Injected: 1.jpg\""))
        // 주입된 헤더가 독립된 헤더 줄로 존재하지 않아야 한다.
        #expect(!text.contains("\r\nX-Injected: 1"))
    }

    @Test("기본 경계는 호출마다 달라진다")
    func defaultBoundaryIsUnique() {
        #expect(MultipartBody().boundary != MultipartBody().boundary)
    }

    @Test("빈 파일도 구조를 유지한다")
    func emptyPayloadKeepsStructure() {
        let (_, text) = makeBody(payload: Data())
        #expect(text == "--TESTBOUNDARY\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n"
            + "Content-Type: image/jpeg\r\n\r\n"
            + "\r\n"
            + "--TESTBOUNDARY--\r\n")
    }
}
