import Foundation
import Testing

@testable import MyApp

/// errorCode 매핑과 폴백. 손으로는 재현할 수 없는 경로(미지 코드·errorCode 부재·계약 밖 본문)를
/// 덮는 것이 목적이다 — 실제로 서버가 문서에 없는 코드를 발행하고 있어
/// (`api/server-contract-mismatch-2026-09-10.md` M2·M3) 이 폴백이 무너지면 모든 오류가
/// "알 수 없는 오류"로 보인다.
@Suite("AnalysisError 매핑")
struct AnalysisErrorTests {

    private func problem(
        status: Int,
        errorCode: String?,
        detail: String? = nil
    ) -> AuthAPIError {
        .problem(
            ProblemDetail(
                type: nil,
                title: nil,
                status: status,
                detail: detail,
                instance: nil,
                errorCode: errorCode,
                timestamp: nil,
                violations: nil
            ),
            status: status
        )
    }

    // MARK: 스펙에 문서화된 코드

    @Test("502 DETECTION_SERVICE_UNAVAILABLE")
    func detectionUnavailable() {
        let error = AnalysisError(apiError: problem(status: 502, errorCode: "DETECTION_SERVICE_UNAVAILABLE"))
        guard case .detectionServiceUnavailable = error else {
            Issue.record("기대: detectionServiceUnavailable, 실제: \(error)")
            return
        }
        #expect(error.isRetryable)
    }

    @Test("404 ANALYSIS_JOB_NOT_FOUND")
    func jobNotFound() {
        let error = AnalysisError(apiError: problem(status: 404, errorCode: "ANALYSIS_JOB_NOT_FOUND"))
        guard case .jobNotFound = error else {
            Issue.record("기대: jobNotFound, 실제: \(error)")
            return
        }
    }

    // MARK: 스펙에 **없는** 코드 (M2) — 서버가 실제로 발행한다

    @Test("스펙에 없는 INVALID_*_FILE 3종이 서버 detail 을 그대로 노출한다", arguments: [
        "INVALID_IMAGE_FILE",
        "INVALID_AUDIO_FILE",
        "INVALID_VIDEO_FILE",
    ])
    func invalidFileCodes(code: String) {
        let error = AnalysisError(
            apiError: problem(status: 400, errorCode: code, detail: "지원하지 않는 파일 형식입니다: image/heic")
        )
        guard case .invalidFile(let message) = error else {
            Issue.record("기대: invalidFile, 실제: \(error)")
            return
        }
        // 문구를 재작성하면 "image/heic" 같은 구체적 원인이 사라진다.
        #expect(message == "지원하지 않는 파일 형식입니다: image/heic")
        // 같은 파일로 재시도해도 결과가 같으므로 재시도 버튼을 띄우지 않는다.
        #expect(!error.isRetryable)
    }

    /// 서버 `handleExceptionInternal` 이 프레임워크 레벨 오류에 `HttpStatus.name()` 을
    /// 백필한다(M3). 닫힌 enum 으로 디코딩했다면 여기서 오류 본문 전체를 잃는다.
    @Test("문서에 없는 errorCode 라도 detail 이 있으면 살린다")
    func undocumentedCodeUsesDetail() {
        let error = AnalysisError(
            apiError: problem(status: 415, errorCode: "UNSUPPORTED_MEDIA_TYPE", detail: "지원하지 않는 미디어 타입입니다.")
        )
        #expect(error.errorDescription == "지원하지 않는 미디어 타입입니다.")
    }

    @Test("errorCode 가 없어도 detail 이 있으면 살린다")
    func missingCodeUsesDetail() {
        let error = AnalysisError(apiError: problem(status: 400, errorCode: nil, detail: "본문을 읽을 수 없습니다."))
        #expect(error.errorDescription == "본문을 읽을 수 없습니다.")
    }

    // MARK: 상태코드 폴백

    @Test("errorCode 도 detail 도 없으면 상태코드로 떨어진다")
    func statusFallback() {
        let unauthorized = AnalysisError(apiError: .http(status: 401))
        guard case .sessionExpired = unauthorized else {
            Issue.record("401 → sessionExpired 기대, 실제: \(unauthorized)")
            return
        }

        let tooLarge = AnalysisError(apiError: .http(status: 413))
        guard case .invalidFile = tooLarge else {
            Issue.record("413 → invalidFile 기대, 실제: \(tooLarge)")
            return
        }

        let server = AnalysisError(apiError: .http(status: 503))
        guard case .server = server else {
            Issue.record("503 → server 기대, 실제: \(server)")
            return
        }
    }

    @Test("전송 오류는 network, 디코딩 실패는 server")
    func transportAndDecoding() {
        let network = AnalysisError(apiError: .transport(URLError(.notConnectedToInternet)))
        guard case .network = network else {
            Issue.record("기대: network, 실제: \(network)")
            return
        }

        let decoding = AnalysisError(apiError: .decoding(URLError(.cannotParseResponse)))
        guard case .server = decoding else {
            Issue.record("기대: server, 실제: \(decoding)")
            return
        }
    }

    @Test("모든 케이스에 사용자 문구가 있다")
    func everyCaseHasMessage() {
        let cases: [AnalysisError] = [
            .invalidFile("a"), .detectionServiceUnavailable, .jobNotFound, .sessionExpired,
            .unsupportedInput("b"), .network, .server, .jobFailed("c"), .unknown("d"),
        ]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false, "문구 누락: \(error)")
        }
    }
}

/// 업로드 전 선검증. 서버 `validate()` 와 값이 어긋나면 유효한 파일을 클라가 막거나(회귀)
/// 못 받는 파일을 올려 보내게 된다.
@Suite("UploadRule 선검증")
struct UploadRuleTests {

    private func file(_ kind: UploadFile.Kind, _ contentType: String, bytes: Int = 16) -> UploadFile {
        UploadFile(
            kind: kind,
            filename: "f",
            contentType: contentType,
            data: Data(repeating: 0, count: bytes)
        )
    }

    @Test("빈 파일은 막는다")
    func emptyBlocked() {
        #expect(UploadRule.submitBlockingHint(for: file(.image, "image/jpeg", bytes: 0)) != nil)
    }

    @Test("서버가 허용하는 형식은 통과한다", arguments: [
        (UploadFile.Kind.image, "image/jpeg"),
        (.image, "image/png"),
        (.image, "image/webp"),
        (.audio, "audio/wav"),
        (.audio, "audio/x-wav"),
        (.audio, "audio/mpeg"),
        (.audio, "audio/mp4"),
        (.audio, "audio/aac"),
        (.video, "video/mp4"),
        (.video, "video/quicktime"),
        (.video, "video/x-msvideo"),
    ])
    func allowedTypesPass(kind: UploadFile.Kind, contentType: String) {
        #expect(UploadRule.submitBlockingHint(for: file(kind, contentType)) == nil)
    }

    /// HEIC 은 iPhone 기본 촬영 포맷이다 — 변환 없이 올리면 서버가 400 을 낸다.
    @Test("HEIC 은 막는다 (변환 누락 탐지)")
    func heicBlocked() {
        #expect(UploadRule.submitBlockingHint(for: file(.image, "image/heic")) != nil)
    }

    @Test("음성 25MB · 영상 100MB 상한을 넘으면 막는다")
    func sizeLimits() {
        #expect(UploadRule.submitBlockingHint(for: file(.audio, "audio/mpeg", bytes: UploadRule.audioMaxBytes + 1)) != nil)
        #expect(UploadRule.submitBlockingHint(for: file(.audio, "audio/mpeg", bytes: UploadRule.audioMaxBytes)) == nil)
        #expect(UploadRule.submitBlockingHint(for: file(.video, "video/mp4", bytes: UploadRule.videoMaxBytes + 1)) != nil)
    }
}

/// 서버 `Evidence` → UI 근거 매핑.
@Suite("EvidenceItem 매핑")
struct EvidenceMappingTests {

    private func dto(tags: [String], startSec: Double = 0.5, endSec: Double = 1.2) -> EvidenceDTO {
        EvidenceDTO(
            title: "시간 구간 이상 패턴",
            description: "합성 흔적이 감지됨",
            tags: tags,
            startSec: startSec,
            endSec: endSec
        )
    }

    /// 서버가 심각도를 주지 않으므로 전체 점수에서 역산해 붙이지 않는다.
    @Test("severity 는 항상 nil 이다")
    func severityAlwaysNil() {
        #expect(EvidenceItem(dto: dto(tags: ["temporal"])).severity == nil)
    }

    @Test("tag 로 아이콘을 고르고 미지 tag 는 기본값으로 떨어진다", arguments: [
        (["temporal"], "waveform.path.ecg"),
        (["spatial"], "square.grid.3x3"),
        (["spectral"], "waveform"),
        (["관측되지않은태그"], "doc.text.magnifyingglass"),
        ([], "doc.text.magnifyingglass"),
    ])
    func iconByTag(tags: [String], expected: String) {
        #expect(EvidenceItem(dto: dto(tags: tags)).icon == expected)
    }

    @Test("구간이 본문에 덧붙는다")
    func timeRangeAppended() {
        let item = EvidenceItem(dto: dto(tags: ["temporal"]))
        #expect(item.detail.contains("0.5초~1.2초"))
    }

    @Test("구간이 0 이면 덧붙이지 않는다")
    func zeroRangeOmitted() {
        let item = EvidenceItem(dto: dto(tags: ["temporal"], startSec: 0, endSec: 0))
        #expect(item.detail == "합성 흔적이 감지됨")
    }
}
