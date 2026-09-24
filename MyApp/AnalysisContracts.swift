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

/// 근거 카드. 음성·영상만 채워진다 — 이미지(SPAI)는 근거를 만들지 않아 필드 자체가 없다.
nonisolated struct EvidenceDTO: Decodable, Sendable {
    let title: String
    let description: String
    let tags: [String]
    let startSec: Double
    let endSec: Double
}

/// `POST /analysis/image`(200)의 `aiDetection`, 그리고 `GET /analysis/records` 의 `imageDetection`.
///
/// **`evidence` 필드를 두지 않는다.** 스키마(`ImageDetectionResult`)와 Java `record` 어디에도 없는
/// 필드다. 2026-09-24 명세에서 예시도 제거됐다(불일치 보고서 M1 해소).
nonisolated struct ImageDetectionDTO: Decodable, Sendable {
    let model: String
    let score: Double
    /// 판독 근거 히트맵(base64 PNG). best-effort — 서버가 만들지 못하면 **키 자체가 빠진다**.
    /// (2026-09-24 명세부터 실제로 내려온다. 이전의 "구현 보류 중, 항상 null"은 낡은 설명이다.)
    let evidenceImage: String?
}

/// `POST /analysis/audio`(200)의 `aiDetection`, 그리고 records 의 `audioDetection`.
nonisolated struct AudioDetectionDTO: Decodable, Sendable {
    let model: String
    let score: Double
    let evidence: [EvidenceDTO]
}

/// `GET /analysis/jobs/{jobId}` 의 `aiDetection`, 그리고 records 의 `videoDetection`.
nonisolated struct VideoDetectionDTO: Decodable, Sendable {
    let model: String
    let score: Double
    let evidence: [EvidenceDTO]
    /// 히트맵(base64 PNG). best-effort — 서버가 실패하면 키가 빠진다.
    let evidenceImage: String?
}

/// 사기(보이스피싱 등) 탐지 결과의 근거 문장 하나. `score` 는 **서버가 문장별로 준 점수**다.
nonisolated struct ScamEvidenceDTO: Decodable, Sendable {
    let sentence: String
    let score: Double
}

/// image / audio 응답, 영상 job(COMPLETED), records 항목에 공통으로 붙는 `scamDetection`.
///
/// **image/audio 에서는 키가 없으면 "텍스트(발화)가 없었다"는 뜻이다**(서버 2026-09-22 정책).
/// 사기감지 파이프라인이 실패하면 키를 빼는 게 아니라 요청 전체가 502 로 실패한다.
/// **영상 job·기록에 대해서는 명세가 이 규칙을 적지 않았다**(계약 확인 항목 17) — 영상에서 부재가
/// "발화 없음"인지 "사기감지 실패"인지 알 수 없다. 그래서 클라는 부재를 어디서든 **카드를 숨기는 것**으로만
/// 다루고, "텍스트가 없었다"고 사용자에게 단정하는 문구는 쓰지 않는다.
nonisolated struct ScamDetectionDTO: Decodable, Sendable {
    let model: String
    let score: Double
    /// **옵셔널로 받는다** — 부재·`null`·`[]` 모두 "근거 문장 없음"(매핑에서 빈 배열). 명세 예시에는
    /// 항상 있지만, 오디오 `aiDetection.evidence` 처럼 "없으면 `[]`" 라는 보장이 명세에 없다(계약 확인 항목 18). 서버의 null 생략 정책(2026-09-23) 아래에서 빈 목록이 null 로 들고
    /// 있다가 키째 빠지면, 필수로 둔 이 한 필드 때문에 **점수까지 포함한 응답 전체**가 디코딩
    /// 실패한다 — 근거 문장은 부가 정보라 없는 편이 훨씬 낫다.
    let evidence: [ScamEvidenceDTO]?
}

/// `POST /analysis/image`(200). `aiDetection` 은 명세상 항상 있다.
nonisolated struct ImageAnalysisResponseDTO: Decodable, Sendable {
    let aiDetection: ImageDetectionDTO
    let scamDetection: ScamDetectionDTO?
}

/// `POST /analysis/audio`(200). `aiDetection` 은 명세상 항상 있다.
nonisolated struct AudioAnalysisResponseDTO: Decodable, Sendable {
    let aiDetection: AudioDetectionDTO
    let scamDetection: ScamDetectionDTO?
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
///
/// **`status` 만으로 나머지 필드의 존재를 추측하지 않는다**(서버 명시). `COMPLETED` 여도 얼굴을
/// 못 찾은 영상은 `aiDetection` 이 없고, `scamDetection` 은 그와 별개로 있을 수 있다.
nonisolated struct AnalysisJobDTO: Decodable, Sendable {
    let jobId: String
    let status: String
    let aiDetection: VideoDetectionDTO?
    let scamDetection: ScamDetectionDTO?
    /// job 본문의 사유 코드(problem+json 의 errorCode 와 별개). **열린 집합**이라 `String` 으로 받고
    /// `AnalysisOutcomeCode(rawValue:)` 로 조회만 한다. errorCode 가 있다고 실패가 아니다 —
    /// `COMPLETED` + `NO_FACE_DETECTED` 는 부분 결과다.
    let errorCode: String?
    /// 사용자에게 **그대로 보여줄** 문구. 서버가 표현을 다듬을 수 있어 **분기에 절대 쓰지 않는다.**
    let errorMessage: String?
}

/// 알려진 job 상태 — 디코딩 타입이 아니라 매핑 조회 전용.
enum AnalysisJobStatusCode: String {
    case pending = "PENDING"
    case processing = "PROCESSING"
    case completed = "COMPLETED"
    case failed = "FAILED"
}

/// job 본문(및 records 항목)의 `errorCode` 중 알려진 값 — 조회 전용. **닫힌 집합이 아니다.**
///
/// 계약 스키마 `AnalysisOutcomeCode`(ADR-0016)와 같은 이름이다. problem+json 의 `AnalysisErrorCode` 와
/// **합치지 않는다** — 이것은 200 응답 안의 "결과 사유"이고, 합치면 `NO_FACE_DETECTED` 가 오류로
/// 분류돼 유효한 사기 탐지 결과가 버려진다.
enum AnalysisOutcomeCode: String {
    /// `COMPLETED` 인데 얼굴을 못 찾아 AI 판독만 비어 있다(부분 결과).
    case noFaceDetected = "NO_FACE_DETECTED"
    /// `FAILED` — 처리 자체 실패. 명세상 **같은 영상으로 재시도 가능**하다.
    case analysisFailed = "ANALYSIS_FAILED"
}

// MARK: - 기록 · 통계

/// `GET /analysis/records`(200). 로그인한 회원의 **완료된** 기록, 최신순 최대 10건. 페이지네이션 없음.
///
/// **항목 단위로 관대하게 디코딩하되, 목록 전체가 깨진 것은 오류로 올린다.**
/// - 일부 항목이 스키마와 다르면(필수 키 부재, `videoDetection` 형태 차이 — 명세에 영상 기록 예시가 없다)
///   **그 항목만 건너뛴다.** 한 건의 이상으로 목록 전체를 잃지 않는다.
/// - 원본 배열이 비어 있지 않은데 **전부** 실패하면 `DecodingError` 를 던진다. 그대로 두면 서버 형태가
///   바뀌었을 때(추론한 `videoDetection` 형태가 틀린 경우 등) 사용자가 "아직 분석 기록이 없습니다"라는
///   **거짓 문장**을 본다 — 빈 결과로 성공을 위장하지 않는다(ADR-0017/0018).
/// - `content` 키 부재·`null` 도 계약 위반(`required`, `nullable: false`)이라 오류다. 0건은 `content: []`
///   로 온다 — null 생략 정책 아래에서도 빈 배열은 직렬화된다(명세 p5 `"evidence": []`).
nonisolated struct AnalysisRecordsResponseDTO: Decodable, Sendable {
    let content: [AnalysisRecordDTO]

    init(content: [AnalysisRecordDTO]) {
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case content
    }

    /// 실패한 요소를 건너뛰기 위한 자리표시자. 아무것도 읽지 않고 성공해 컨테이너 인덱스만 넘긴다.
    private struct Skipped: Decodable {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 키 부재·null 이면 여기서 DecodingError(keyNotFound / valueNotFound) — 합성 Decodable 과 같은 동작.
        var items = try container.nestedUnkeyedContainer(forKey: .content)
        var decoded: [AnalysisRecordDTO] = []
        var failures: [String] = []
        while !items.isAtEnd {
            let index = items.currentIndex
            do {
                decoded.append(try items.decode(AnalysisRecordDTO.self))
            } catch {
                failures.append("#\(index): \(error)")
                // 실패한 `decode` 는 인덱스를 넘기지 않는다 — 넘기지 않으면 무한 루프다.
                _ = try items.decode(Skipped.self)
            }
        }
        if !failures.isEmpty {
            #if DEBUG
            print("[Veritae][Records] 디코딩 실패로 건너뛴 항목 \(failures.count)/\(failures.count + decoded.count)건 — \(failures.joined(separator: " | "))")
            #endif
            if decoded.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [CodingKeys.content],
                        debugDescription: "records 항목 \(failures.count)건이 전부 디코딩에 실패했다"
                    )
                )
            }
        }
        content = decoded
    }
}

/// records 항목 하나.
///
/// **원본 미디어(썸네일·파일)는 오지 않는다** — 이 DTO 로 만든 `AnalysisRecord` 는 `input == nil` 이다(ADR-0017).
///
/// detection 필드 이름이 분석 응답(`aiDetection`)과 다르다(`imageDetection`/`audioDetection`/
/// `videoDetection`). 내용 스키마는 각각 같다. 셋 중 `modality` 에 맞는 **하나만** 채워지고 나머지는
/// 키가 없다 — 클라는 `modality` 를 보고 어느 필드를 읽을지 정한다(서버 명시).
nonisolated struct AnalysisRecordDTO: Decodable, Sendable {
    /// `String` — 포맷을 가정하지 않는다(ADR-0012).
    let id: String
    /// `String` — 미지 값이 와도 목록 전체가 깨지지 않게 한다. 조회는 `AnalysisModalityCode`.
    let modality: String
    /// RFC 3339 로 예시돼 있지만 `String` 으로 받는다(ADR-0012). 표시용 파싱은 매핑 단계에서 하고
    /// 실패해도 크래시하지 않는다.
    let createdAt: String
    let imageDetection: ImageDetectionDTO?
    let audioDetection: AudioDetectionDTO?
    /// 얼굴을 못 찾은 영상은 이 키가 없다(`errorCode == NO_FACE_DETECTED`).
    let videoDetection: VideoDetectionDTO?
    let scamDetection: ScamDetectionDTO?
    /// 완료됐지만 일부 판독이 비었을 때만 온다(현재 `NO_FACE_DETECTED`). 열린 집합.
    let errorCode: String?
}

/// records 항목의 `modality` 중 알려진 값 — 조회 전용. 미지 값의 항목은 목록에서 건너뛴다.
enum AnalysisModalityCode: String {
    case image = "IMAGE"
    case audio = "AUDIO"
    case video = "VIDEO"
}

/// `GET /analysis/report`(200). 완료된 기록 집계. `ai/scamDetectedCount` 는 서버가 **점수 0.5 이상**을
/// "탐지됨"으로 센 값이다(고정 임계값 — 클라 `RiskLevel` 구간과 다르다는 점에 주의).
///
/// 전 필드 필수 — 개수는 0 이어도 숫자로 온다(null 이 될 의미가 없다).
nonisolated struct AnalysisReportDTO: Decodable, Sendable {
    let totalCount: Int
    let imageCount: Int
    let audioCount: Int
    let videoCount: Int
    let aiDetectedCount: Int
    let scamDetectedCount: Int
}

/// analysis 엔드포인트가 내는 problem+json errorCode. **닫힌 집합이 아니다** — 디코딩에 쓰지 않고
/// 매핑 조회에만 쓴다. 프레임워크 레벨 오류는 `HttpStatus` enum 이름(예: `UNSUPPORTED_MEDIA_TYPE`)이
/// 온다고 서버가 명시했다(2026-09-24 명세, 불일치 보고서 M3 해소).
///
/// `INVALID_*_FILE` 3종은 2026-09-24 명세 오류 코드 표에 문서화됐다(M2 해소).
enum AnalysisErrorCode: String {
    case invalidImageFile = "INVALID_IMAGE_FILE"
    case invalidAudioFile = "INVALID_AUDIO_FILE"
    case invalidVideoFile = "INVALID_VIDEO_FILE"
    /// image/audio 에서는 "AI 탐지 서버 실패" **또는** "사기감지 파이프라인 실패" 둘 다 이 코드다
    /// (명세상 구분 수단 없음).
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
    /// 응답 본문 전체를 돌려준다 — `aiDetection` 만 떼어 주면 `scamDetection` 이 버려진다.
    nonisolated func analyzeImage(_ file: UploadFile, accessToken: String) async throws -> ImageAnalysisResponseDTO
    nonisolated func analyzeAudio(_ file: UploadFile, accessToken: String) async throws -> AudioAnalysisResponseDTO
    /// 202로 즉시 반환된다 — 결과는 `job(id:accessToken:)`으로 폴링한다.
    nonisolated func submitVideo(_ file: UploadFile, accessToken: String) async throws -> String
    nonisolated func job(id: String, accessToken: String) async throws -> AnalysisJobDTO
    /// `GET /analysis/records` — `content` 배열을 그대로 돌려준다(미지 modality 거르기는 매핑 단계).
    nonisolated func records(accessToken: String) async throws -> [AnalysisRecordDTO]
    /// `GET /analysis/report`. 아직 화면·스토어에 연결하지 않았다(다음 작업).
    nonisolated func report(accessToken: String) async throws -> AnalysisReportDTO
}
