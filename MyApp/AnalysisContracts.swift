import Foundation

// MARK: - 응답 DTO — 서버 `openapi.yaml` 스키마와 1:1
//
// LL-002: 이 파일의 모든 타입에 `nonisolated`를 붙인다. 무표기면 `Decodable` **conformance
// 자체**가 MainActor로 격리 추론돼, `nonisolated`로 표시한 `LiveAnalysisAPI` 메서드 안에서
// `JSONDecoder.decode`에 넘길 때 Swift 6에서 오류가 된다(`AuthContracts.swift`와 같은 이유).
//
// 전송 계층 오류 타입은 auth와 공유한다 — `AuthAPIError`는 이름만 auth이고 실제 내용은
// "problem+json / http / transport / decoding"이라는 전 API 공통 형태다. 새로 만들면
// `AuthSession`의 refresh 재시도 로직까지 복제해야 한다.
// TODO(후속): `AuthAPIError` → `APIError` 로 개명. 이번 사이클에 섞으면 6개 파일이 함께
// 바뀌어 기능 diff를 가린다.

/// 근거 카드. 음성·영상만 채워진다 — 이미지(SPAI)는 근거를 만들지 않아 항상 빈 배열이다.
nonisolated struct EvidenceDTO: Decodable, Sendable {
    let title: String
    let description: String
    let tags: [String]
    let startSec: Double
    let endSec: Double
}

/// `POST /analysis/image`(200)의 `aiDetection`.
///
/// **`evidence` 필드를 두지 않는다.** 서버 스펙의 200 예시에는 `evidence: []`가 있지만
/// 스키마(`ImageDetectionResult`)와 Java `record` 어디에도 없는 필드다
/// (`api/server-contract-mismatch-2026-09-10.md` M1). 예시를 따라 넣으면 정상 응답에서
/// 디코딩이 실패한다.
nonisolated struct ImageDetectionDTO: Decodable, Sendable {
    let model: String
    let score: Double
    /// 히트맵(base64 PNG). 서버가 "구현 보류 중, 항상 null"로 명시했다.
    let evidenceImage: String?
}

nonisolated struct AudioDetectionDTO: Decodable, Sendable {
    let model: String
    let score: Double
    let evidence: [EvidenceDTO]
}

nonisolated struct VideoDetectionDTO: Decodable, Sendable {
    let model: String
    let score: Double
    let evidence: [EvidenceDTO]
    /// 히트맵(base64 PNG). best-effort — 서버가 실패하면 null이다.
    let evidenceImage: String?
}

nonisolated struct ImageAnalysisResponseDTO: Decodable, Sendable {
    let aiDetection: ImageDetectionDTO
}

nonisolated struct AudioAnalysisResponseDTO: Decodable, Sendable {
    let aiDetection: AudioDetectionDTO
}

/// `POST /analysis/video`(202). `jobId`는 `UUID`가 아니라 `String`으로 받는다 — 서버가
/// UUID 포맷을 보장하지 않는 값을 한 번이라도 주면 응답 전체가 디코딩 실패한다(ADR-0012).
nonisolated struct AnalysisJobAcceptedDTO: Decodable, Sendable {
    let jobId: String
}

/// `GET /analysis/jobs/{jobId}`(200).
///
/// `status`도 `String`이다. 서버 `AnalysisJobStatus`에 값이 추가되면 닫힌 `enum`은 그 즉시
/// 디코딩이 깨진다 — 매핑은 `AnalysisJobStatusCode(rawValue:)`로 디코딩 이후에 한다.
nonisolated struct AnalysisJobDTO: Decodable, Sendable {
    let jobId: String
    let status: String
    /// `status == COMPLETED`일 때만 채워진다.
    let aiDetection: VideoDetectionDTO?
    /// `status == FAILED`일 때만 채워진다.
    let errorMessage: String?
}

/// 알려진 job 상태 — 디코딩 타입이 아니라 매핑 조회 전용.
enum AnalysisJobStatusCode: String {
    case pending = "PENDING"
    case processing = "PROCESSING"
    case completed = "COMPLETED"
    case failed = "FAILED"
}

/// analysis 엔드포인트가 내는 errorCode. **닫힌 집합이 아니다** — 디코딩에 쓰지 않고
/// 매핑 조회에만 쓴다.
///
/// 아래 3종은 **서버 스펙에 문서화되어 있지 않다.** 서버 코드에만 존재하며
/// analysis 400의 사실상 모든 경우가 여기다(불일치 보고서 M2). 문서가 안내하는
/// `VALIDATION_FAILED`는 이 엔드포인트들에서 발생할 지점이 없다.
enum AnalysisErrorCode: String {
    case invalidImageFile = "INVALID_IMAGE_FILE"
    case invalidAudioFile = "INVALID_AUDIO_FILE"
    case invalidVideoFile = "INVALID_VIDEO_FILE"
    case detectionServiceUnavailable = "DETECTION_SERVICE_UNAVAILABLE"
    case analysisJobNotFound = "ANALYSIS_JOB_NOT_FOUND"
}

// MARK: - 업로드 입력

/// 업로드할 파일 한 건. 어떤 엔드포인트로 갈지는 `kind`가 결정한다.
nonisolated struct UploadFile: Sendable {
    enum Kind: Sendable {
        case image
        case audio
        case video
    }

    let kind: Kind
    let filename: String
    /// 서버 `validate()`가 이 값으로 형식을 판정한다.
    let contentType: String
    let data: Data
}

// MARK: - AnalysisAPI 프로토콜 (목/실 구현 교체 지점, ADR-0001)

/// `nonisolated` — 프로토콜 요구사항과 구현체 멤버 **양쪽에** 붙여야 한다. 한쪽만 붙이면
/// Swift 6에서 conformance isolation 오류가 난다(LL-002 실측).
///
/// 액세스 토큰을 인자로 받는다 — 토큰 보유·갱신은 `AuthSession` actor의 책임이고
/// (`withValidAccessToken`), 이 계층은 받은 토큰을 헤더에 실을 뿐이다. `AuthAPI.me`와 같은 구조다.
protocol AnalysisAPI: Sendable {
    nonisolated func analyzeImage(_ file: UploadFile, accessToken: String) async throws -> ImageDetectionDTO
    nonisolated func analyzeAudio(_ file: UploadFile, accessToken: String) async throws -> AudioDetectionDTO
    /// 202로 즉시 반환된다 — 결과는 `job(id:accessToken:)`으로 폴링한다.
    nonisolated func submitVideo(_ file: UploadFile, accessToken: String) async throws -> String
    nonisolated func job(id: String, accessToken: String) async throws -> AnalysisJobDTO
}
