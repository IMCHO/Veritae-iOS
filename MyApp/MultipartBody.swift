import Foundation

/// `multipart/form-data` 본문 조립 (RFC 7578). analysis 업로드 3종이 쓴다.
///
/// `nonisolated` — 최대 100MB 파일을 `Data`에 이어 붙이는 작업이다. 무표기로 두면 프로젝트의
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 때문에 이 조립이 메인 스레드에서 돌아
/// 업로드 시작 직전 UI가 멎는다(LL-002). 경고 0건으로 숨는 종류의 문제라 타입 자체에 붙인다.
///
/// 바이트 단위 결과라 화면으로는 검증이 불가능하다 — 경계 문자열·CRLF·종료 경계가 하나라도
/// 틀리면 서버가 파트를 못 읽고 400을 낸다. 단위 테스트로만 확인할 수 있어
/// `MyAppTests/MultipartBodyTests.swift`가 이 타입의 유일한 검증 수단이다.
nonisolated struct MultipartBody: Sendable {
    /// 경계 문자열. 본문 어디에도 나타나지 않아야 한다 — UUID를 써서 충돌을 실질적으로 배제한다.
    let boundary: String

    private var body = Data()

    init(boundary: String = "VeritaeBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// `Content-Type` 헤더 값. 요청에 이 값을 그대로 실어야 서버가 경계를 찾을 수 있다.
    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// 파일 파트 하나를 추가한다.
    ///
    /// - Parameters:
    ///   - name: form 필드 이름. 서버 계약은 전부 `file` 이다.
    ///   - filename: 서버가 확장자를 보는 경우가 있어 원본 이름을 유지한다.
    ///   - contentType: 서버 `validate()`가 이 값으로 형식을 판정한다 — 실제 파일과 어긋나면
    ///     400 `INVALID_*_FILE`이 된다.
    mutating func appendFile(name: String, filename: String, contentType: String, data fileData: Data) {
        appendString("--\(boundary)\r\n")
        appendString(
            "Content-Disposition: form-data; name=\"\(Self.escapeHeaderValue(name))\";"
            + " filename=\"\(Self.escapeHeaderValue(filename))\"\r\n"
        )
        appendString("Content-Type: \(contentType)\r\n\r\n")
        body.append(fileData)
        appendString("\r\n")
    }

    /// 종료 경계까지 붙인 최종 본문. **이 값을 요청에 실어야 한다** — 종료 경계가 없으면
    /// 서버는 본문이 잘린 것으로 보고 파트를 버린다.
    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func appendString(_ string: String) {
        body.append(Data(string.utf8))
    }

    /// 헤더 값에 들어가면 파트 구조를 깨뜨리는 문자를 제거한다.
    ///
    /// 파일 이름은 사용자가 고른 값이라 통제할 수 없다. 큰따옴표가 들어오면
    /// `filename="..."` 을 조기 종료시키고, CR/LF는 헤더를 갈라 **본문에 임의 헤더를
    /// 주입**할 수 있다. 인코딩(RFC 2231) 대신 제거를 택한 건 서버가 파일 이름을
    /// 형식 판정에 쓰지 않아(Content-Type을 본다) 이름 손실이 무해하기 때문이다.
    ///
    /// **`Character` 가 아니라 유니코드 스칼라 단위로 걸러야 한다.** Swift 에서 CRLF(`\r\n`)는
    /// 하나의 `Character`(grapheme cluster)이므로 `filter { $0 != "\r" && $0 != "\n" }` 로는
    /// **CRLF 가 그대로 통과한다** — 즉 헤더 주입이 전혀 막히지 않는다. 처음 이렇게 썼다가
    /// `MultipartBodyTests`가 잡아냈다. 스칼라 단위에서는 CR 과 LF 가 별개라 정상 제거된다.
    private nonisolated static func escapeHeaderValue(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" }
        return String(String.UnicodeScalarView(scalars))
    }
}
