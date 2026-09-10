import Foundation
import Testing

@testable import MyApp

/// 이미지 Content-Type 을 **확장자가 아니라 바이트로** 판정하는 로직.
///
/// 확장자를 믿으면 `.jpg` 로 저장된 HEIC 를 `image/jpeg` 로 거짓 신고해 서버에서 400 이 난다.
/// 그런데 그 실패는 **실서버에서만** 드러난다 — 목은 Content-Type 을 검증하지 않기 때문에
/// 목으로 아무리 눌러 봐도 재현되지 않는다. 그래서 단위 테스트가 유일한 검증 수단이다.
@Suite("ImageByteFormat")
struct ImageByteFormatTests {

    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 16))
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 16))
    /// "RIFF" + 크기 4바이트 + "WEBP"
    private static let webp = Data(
        [0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50]
            + [UInt8](repeating: 0, count: 8)
    )
    /// HEIC — `ftypheic` 박스. 서버가 받지 않는 형식이라 판별에서 빠져야 한다.
    private static let heic = Data(
        [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]
            + [UInt8](repeating: 0, count: 8)
    )

    @Test("서버가 그대로 받는 3종을 매직 바이트로 식별한다")
    func detectsPassthroughFormats() {
        #expect(ImageByteFormat(data: Self.jpeg)?.contentType == "image/jpeg")
        #expect(ImageByteFormat(data: Self.png)?.contentType == "image/png")
        #expect(ImageByteFormat(data: Self.webp)?.contentType == "image/webp")
    }

    @Test("확장자와 무관하게 바이트로 판정한다")
    func extensionIsIrrelevant() async {
        // `.jpg` 라는 이름을 달고 있어도 실제 바이트가 PNG 면 image/png 로 나가야 한다.
        let file = await UploadFileFactory.image(from: Self.png, filename: "사진.jpg")
        #expect(file?.contentType == "image/png")
    }

    /// 이게 원래 버그였다 — HEIC 를 확장자만 보고 통과시키면 서버가 400 을 낸다.
    @Test("HEIC 는 통과 형식이 아니다")
    func heicIsNotPassthrough() {
        #expect(ImageByteFormat(data: Self.heic) == nil)
    }

    @Test("빈 데이터·짧은 데이터·쓰레기 값에서 nil")
    func rejectsInvalid() {
        #expect(ImageByteFormat(data: Data()) == nil)
        #expect(ImageByteFormat(data: Data([0xFF, 0xD8])) == nil)          // JPEG 매직이 3바이트인데 2바이트뿐
        #expect(ImageByteFormat(data: Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    /// RIFF 컨테이너는 WebP 전용이 아니다(WAV 도 RIFF 다) — 뒤 4바이트까지 봐야 한다.
    @Test("RIFF 이지만 WEBP 가 아니면 nil")
    func riffWithoutWebpIsNil() {
        let wav = Data(
            [0x52, 0x49, 0x46, 0x46, 0x10, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45]  // "WAVE"
                + [UInt8](repeating: 0, count: 8)
        )
        #expect(ImageByteFormat(data: wav) == nil)
    }

    @Test("파일명이 없으면 판정 결과의 확장자로 만든다")
    func derivesFilenameFromFormat() async {
        let file = await UploadFileFactory.image(from: Self.png)
        #expect(file?.filename == "image.png")
    }

    @Test("디코딩도 안 되는 데이터는 nil — 재인코딩할 수 없다")
    func undecodableReturnsNil() async {
        let garbage = Data([UInt8](repeating: 0x7F, count: 64))
        #expect(await UploadFileFactory.image(from: garbage) == nil)
    }

    /// 판정된 형식은 `UploadRule` 선검증도 통과해야 한다 — 두 곳이 어긋나면 방금 만든
    /// 파일을 우리 스스로 거절한다.
    @Test("판정 결과가 UploadRule 을 통과한다")
    func sniffedTypesPassUploadRule() async {
        for data in [Self.jpeg, Self.png, Self.webp] {
            let file = await UploadFileFactory.image(from: data)
            let unwrapped = try? #require(file)
            guard let unwrapped else { continue }
            #expect(UploadRule.submitBlockingHint(for: unwrapped) == nil)
        }
    }
}

/// 파일 선택 경로(`fromFile(url:)`). 확장자 → Content-Type 매핑, 용량 게이트, 미지원 형식 거절.
///
/// 이 경로는 원래 두 가지가 깨져 있었다 — security-scoped 접근을 열지 않아 파일 앱에서 고른
/// 파일을 읽지 못했고, 용량을 읽은 뒤에 검사해서 100MB 영상을 통째로 메모리에 올렸다.
@Suite("UploadFileFactory.fromFile")
struct UploadFileFromFileTests {


    /// `#expect(throws:)` 매크로는 async throwing 클로저에서 `try` 처리를 못 해 컴파일이 깨진다.
    /// do/catch 로 직접 확인한다.
    private func expectUploadFileError(
        _ body: () async throws -> UploadFile?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            _ = try await body()
            Issue.record("UploadFileError 를 기대했지만 성공했다", sourceLocation: sourceLocation)
        } catch is UploadFileError {
            // 기대한 경로
        } catch {
            Issue.record("UploadFileError 를 기대했는데 \(error)", sourceLocation: sourceLocation)
        }
    }

    /// 테스트마다 고유한 임시 파일을 만든다. 내용은 형식 판정에 쓰이지 않는다(확장자로 판정).
    private func makeTempFile(name: String, bytes: Int = 32) throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "veritae-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test("영상 확장자를 서버 허용 Content-Type 으로 매핑한다", arguments: [
        ("clip.mp4", "video/mp4"),
        ("clip.mov", "video/quicktime"),
        ("clip.MOV", "video/quicktime"),   // 대문자 확장자도 같아야 한다
        ("clip.avi", "video/x-msvideo"),
    ])
    func videoContentTypes(name: String, expected: String) async throws {
        let url = try makeTempFile(name: name)
        let file = try #require(await UploadFileFactory.fromFile(url: url))
        #expect(file.kind == .video)
        #expect(file.contentType == expected)
        // 방금 만든 파일을 우리 선검증이 거절하면 안 된다.
        #expect(UploadRule.submitBlockingHint(for: file) == nil)
    }

    @Test("음성 확장자를 서버 허용 Content-Type 으로 매핑한다", arguments: [
        ("a.wav", "audio/wav"),
        ("a.mp3", "audio/mpeg"),
        ("a.m4a", "audio/mp4"),
        ("a.aac", "audio/aac"),
    ])
    func audioContentTypes(name: String, expected: String) async throws {
        let url = try makeTempFile(name: name)
        let file = try #require(await UploadFileFactory.fromFile(url: url))
        #expect(file.kind == .audio)
        #expect(file.contentType == expected)
        #expect(UploadRule.submitBlockingHint(for: file) == nil)
    }

    @Test("이미지는 바이트로 판정한다 — 확장자가 없어도 된다")
    func imageDetectedByBytes() async throws {
        let dir = URL.temporaryDirectory.appending(path: "veritae-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "확장자없음")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 16))
            .write(to: url)

        let file = try #require(await UploadFileFactory.fromFile(url: url))
        #expect(file.kind == .image)
        #expect(file.contentType == "image/png")
    }

    @Test("서버가 받지 않는 형식은 nil — 업로드 시도조차 하지 않는다")
    func unsupportedReturnsNil() async throws {
        let url = try makeTempFile(name: "문서.pdf")
        let file = try await UploadFileFactory.fromFile(url: url)
        #expect(file == nil)
    }

    /// **읽기 전에** 용량으로 거절해야 한다. 나중에 검사하면 100MB 를 메모리에 올린 뒤 버린다.
    @Test("영상 100MB 초과는 읽지 않고 거절한다")
    func oversizedVideoRejectedBeforeRead() async throws {
        let url = try makeTempFile(name: "big.mp4", bytes: UploadRule.videoMaxBytes + 1)
        await expectUploadFileError { try await UploadFileFactory.fromFile(url: url) }
    }

    @Test("음성 25MB 초과는 읽지 않고 거절한다")
    func oversizedAudioRejectedBeforeRead() async throws {
        let url = try makeTempFile(name: "big.mp3", bytes: UploadRule.audioMaxBytes + 1)
        await expectUploadFileError { try await UploadFileFactory.fromFile(url: url) }
    }

    @Test("용량 안내 문구에 실제 크기가 들어간다")
    func sizeMessageMentionsActualSize() async throws {
        let url = try makeTempFile(name: "big.mp4", bytes: UploadRule.videoMaxBytes + 1)
        do {
            _ = try await UploadFileFactory.fromFile(url: url)
            Issue.record("throw 를 기대했다")
        } catch let error as UploadFileError {
            #expect(error.message.contains("100MB"))
            #expect(error.message.contains("MB입니다"))
        }
    }

    @Test("읽을 수 없는 경로는 unreadable 로 알린다")
    func missingFileIsUnreadable() async {
        let url = URL.temporaryDirectory.appending(path: "없는파일-\(UUID().uuidString).mp4")
        await expectUploadFileError { try await UploadFileFactory.fromFile(url: url) }
    }

    /// PhotosPicker 영상은 `Data` 가 아니라 파일 URL 표현으로 받아야 한다 — 이 표현이
    /// `.movie` 를 대상으로 선언돼 있는지 확인한다. (실제 로딩은 시스템 피커가 필요해
    /// 단위 테스트로 검증할 수 없다.)
    @Test("PickedMovie 는 파일 표현으로 선언되어 있다")
    func pickedMovieUsesFileRepresentation() {
        #expect(String(describing: PickedMovie.transferRepresentation).contains("FileRepresentation"))
    }
}
