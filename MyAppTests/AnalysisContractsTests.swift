import Foundation
import Testing

@testable import MyApp

/// 2026-09-24 명세의 응답 예시를 그대로 디코딩한다. 서버는 null 필드의 **키 자체를 뺀다**
/// (2026-09-23 정책) — 키 부재가 디코딩 실패로 번지지 않는지가 핵심이다.
@Suite("분석 응답 DTO 디코딩")
struct AnalysisContractsDecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// 1x1 PNG. 명세 예시의 `"iVBORw0KGgo... (생략)"` 은 유효한 base64 가 아니라 그대로 쓰지 않는다.
    static let tinyPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

    // MARK: scamDetection

    @Test("이미지 — scamDetection·evidenceImage 가 있는 예시")
    func imageWithScam() throws {
        let dto = try decode(ImageAnalysisResponseDTO.self, """
        {
          "aiDetection": { "model": "spai", "score": 0.97, "evidenceImage": "\(Self.tinyPNG)" },
          "scamDetection": {
            "model": "lilju", "score": 0.82,
            "evidence": [ { "sentence": "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", "score": 0.95 } ]
          }
        }
        """)
        #expect(dto.aiDetection.score == 0.97)
        #expect(dto.aiDetection.evidenceImage == Self.tinyPNG)
        let scam = try #require(dto.scamDetection)
        #expect(scam.model == "lilju")
        #expect(scam.score == 0.82)
        #expect(scam.evidence?.first?.sentence == "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.")
        #expect(scam.evidence?.first?.score == 0.95)
    }

    @Test("이미지 — 텍스트가 없으면 scamDetection·evidenceImage 키가 없다")
    func imageWithoutScam() throws {
        let dto = try decode(ImageAnalysisResponseDTO.self, """
        { "aiDetection": { "model": "spai", "score": 0.000134 } }
        """)
        #expect(dto.aiDetection.score == 0.000134)
        #expect(dto.aiDetection.evidenceImage == nil)
        #expect(dto.scamDetection == nil)
    }

    @Test("음성 — scamDetection 유무 모두 디코딩된다")
    func audioWithAndWithoutScam() throws {
        let with = try decode(AudioAnalysisResponseDTO.self, """
        {
          "aiDetection": {
            "model": "antideepfake", "score": 0.0018,
            "evidence": [ { "title": "시간 구간 이상 패턴", "description": "0.5초~1.2초 구간에서 합성 흔적이 감지됨",
                            "tags": ["temporal"], "startSec": 0.5, "endSec": 1.2 } ]
          },
          "scamDetection": { "model": "lilju", "score": 0.82,
                             "evidence": [ { "sentence": "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", "score": 0.95 } ] }
        }
        """)
        #expect(with.aiDetection.evidence.count == 1)
        #expect(with.scamDetection?.score == 0.82)

        let without = try decode(AudioAnalysisResponseDTO.self, """
        { "aiDetection": { "model": "antideepfake", "score": 0.0018, "evidence": [] } }
        """)
        #expect(without.aiDetection.evidence.isEmpty)
        #expect(without.scamDetection == nil)
    }

    /// 명세가 "없으면 `[]`" 를 보장하지 않는 필드다. 필수로 두면 이 한 키 때문에 점수까지 잃는다.
    @Test("scamDetection.evidence 키가 빠져도 점수는 살린다")
    func scamWithoutEvidenceKey() throws {
        let dto = try decode(ImageAnalysisResponseDTO.self, """
        { "aiDetection": { "model": "spai", "score": 0.1 }, "scamDetection": { "model": "lilju", "score": 0.6 } }
        """)
        #expect(dto.scamDetection?.score == 0.6)
        #expect(dto.scamDetection?.evidence == nil)
    }

    // MARK: 영상 job

    @Test("job — 진행 중 예시는 jobId·status 만 온다")
    func jobInProgress() throws {
        let dto = try decode(AnalysisJobDTO.self, """
        { "jobId": "11111111-1111-1111-1111-111111111111", "status": "PROCESSING" }
        """)
        #expect(dto.status == "PROCESSING")
        #expect(dto.aiDetection == nil)
        #expect(dto.scamDetection == nil)
        #expect(dto.errorCode == nil)
        #expect(dto.errorMessage == nil)
    }

    @Test("job — 얼굴 없음 예시: COMPLETED 인데 aiDetection 없음, scamDetection·errorCode 있음")
    func jobNoFace() throws {
        let dto = try decode(AnalysisJobDTO.self, """
        {
          "jobId": "11111111-1111-1111-1111-111111111111",
          "status": "COMPLETED",
          "scamDetection": { "model": "lilju", "score": 0.82,
                             "evidence": [ { "sentence": "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", "score": 0.95 } ] },
          "errorCode": "NO_FACE_DETECTED",
          "errorMessage": "영상에서 얼굴을 찾을 수 없어 AI판독은 제공되지 않습니다."
        }
        """)
        #expect(AnalysisJobStatusCode(rawValue: dto.status) == .completed)
        #expect(dto.aiDetection == nil)
        #expect(dto.scamDetection != nil)
        #expect(dto.errorCode.flatMap(AnalysisOutcomeCode.init(rawValue:)) == .noFaceDetected)
    }

    @Test("job — 완전 실패 예시")
    func jobFailed() throws {
        let dto = try decode(AnalysisJobDTO.self, """
        { "jobId": "1", "status": "FAILED", "errorCode": "ANALYSIS_FAILED", "errorMessage": "영상 분석 중 오류가 발생했습니다." }
        """)
        #expect(dto.errorCode.flatMap(AnalysisOutcomeCode.init(rawValue:)) == .analysisFailed)
    }

    /// 열린 집합 — 미지 코드가 와도 디코딩은 성공하고 조회만 `nil` 이다.
    @Test("job — 미지 errorCode 도 디코딩된다")
    func jobUnknownErrorCode() throws {
        let dto = try decode(AnalysisJobDTO.self, """
        { "jobId": "1", "status": "COMPLETED", "errorCode": "SOMETHING_NEW" }
        """)
        #expect(dto.errorCode == "SOMETHING_NEW")
        #expect(dto.errorCode.flatMap(AnalysisOutcomeCode.init(rawValue:)) == nil)
    }

    // MARK: 통계

    @Test("report — 명세 예시")
    func report() throws {
        let dto = try decode(AnalysisReportDTO.self, """
        { "totalCount": 23, "imageCount": 10, "audioCount": 8, "videoCount": 5,
          "aiDetectedCount": 3, "scamDetectedCount": 2 }
        """)
        #expect(dto.totalCount == 23)
        #expect(dto.imageCount == 10)
        #expect(dto.audioCount == 8)
        #expect(dto.videoCount == 5)
        #expect(dto.aiDetectedCount == 3)
        #expect(dto.scamDetectedCount == 2)
    }
}

/// `GET /analysis/records` → `AnalysisRecord`. 서버 기록은 원본 미디어가 없다(ADR-0017).
@Suite("분석 기록 디코딩·매핑")
@MainActor
struct AnalysisRecordsMappingTests {

    /// 명세 9번 예시 3건 + 미지 modality + 날짜 파싱 실패 + modality 와 다른 detection 이 섞인 항목.
    private static let json = """
    {
      "content": [
        {
          "id": "11111111-1111-1111-1111-111111111111", "modality": "IMAGE", "createdAt": "2026-09-23T09:00:00Z",
          "imageDetection": { "model": "spai", "score": 0.87, "evidenceImage": "\(AnalysisContractsDecodingTests.tinyPNG)" }
        },
        {
          "id": "22222222-2222-2222-2222-222222222222", "modality": "AUDIO", "createdAt": "2026-09-23T08:30:00Z",
          "audioDetection": {
            "model": "antideepfake", "score": 0.73,
            "evidence": [ { "title": "합성 음성 의심 구간", "description": "1.0초~4.0초 구간에서 부자연스러운 음성 합성 흔적이 감지됨",
                            "tags": ["temporal"], "startSec": 1.0, "endSec": 4.0 } ]
          },
          "scamDetection": { "model": "lilju", "score": 0.82,
                             "evidence": [ { "sentence": "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", "score": 0.95 } ] }
        },
        {
          "id": "33333333-3333-3333-3333-333333333333", "modality": "VIDEO", "createdAt": "2026-09-23T08:00:00Z",
          "scamDetection": { "model": "lilju", "score": 0.82,
                             "evidence": [ { "sentence": "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", "score": 0.95 } ] },
          "errorCode": "NO_FACE_DETECTED"
        },
        { "id": "44444444", "modality": "TEXT", "createdAt": "2026-09-23T07:00:00Z" },
        {
          "id": "55555555", "modality": "IMAGE", "createdAt": "어제 오후",
          "imageDetection": { "model": "spai", "score": 0.2 }
        },
        {
          "id": "66666666", "modality": "IMAGE", "createdAt": "2026-09-23T06:00:00.123456Z",
          "imageDetection": { "model": "spai", "score": 0.5 },
          "audioDetection": { "model": "antideepfake", "score": 0.99, "evidence": [] }
        }
      ]
    }
    """

    private func mapped() throws -> [AnalysisRecord] {
        let dto = try JSONDecoder().decode(AnalysisRecordsResponseDTO.self, from: Data(Self.json.utf8))
        return dto.content.compactMap(AnalysisRecord.init(server:))
    }

    @Test("미지 modality 항목만 건너뛰고 나머지는 서버 순서대로 남는다")
    func unknownModalitySkipped() throws {
        let records = try mapped()
        #expect(records.map(\.id) == [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
            "33333333-3333-3333-3333-333333333333",
            "55555555",
            "66666666",
        ])
        #expect(records.allSatisfy { $0.input == nil })
    }

    @Test("modality 별로 맞는 detection 필드를 읽는다")
    func modalitySelectsDetectionField() throws {
        let records = try mapped()

        let image = records[0]
        #expect(image.modality == .image)
        #expect(image.aiProbability == 0.87)
        #expect(image.model == "spai")
        // 이미지 히트맵도 실제로 내려온다 — 버리지 않는다.
        #expect(image.evidenceImage != nil)
        #expect(image.riskLevel == nil)

        let audio = records[1]
        #expect(audio.modality == .audio)
        #expect(audio.aiProbability == 0.73)
        #expect(audio.aiEvidence.first?.timeRange == 1.0...4.0)
        #expect(audio.riskLevel == .high)
        #expect(audio.riskEvidence.count == 1)

        // IMAGE 항목에 audioDetection 이 섞여 와도 modality 에 맞는 필드만 읽는다.
        let mixed = records[4]
        #expect(mixed.aiProbability == 0.5)
        #expect(mixed.model == "spai")
    }

    @Test("얼굴 없는 영상 기록 — AI 판독 없음 + 사기 탐지 + errorCode 로 고른 안내")
    func noFaceVideoRecord() throws {
        let video = try mapped()[2]
        #expect(video.modality == .video)
        #expect(video.aiProbability == nil)
        #expect(video.aiLevel == nil)
        #expect(video.model == nil)
        #expect(video.riskLevel == .high)
        // 기록 항목에는 errorMessage 가 없다 — errorCode 로 문구를 고른다.
        #expect(video.notice == AnalysisRecord.missingAINotice(errorCode: "NO_FACE_DETECTED"))
    }

    /// 한 건의 이상으로 목록 전체를 잃지 않는다. 명세에 영상 기록(`videoDetection`) 예시가 없어 형태가
    /// 기존 스키마와 다를 수 있다.
    @Test("스키마와 다른 항목은 그 항목만 건너뛰고 나머지는 살린다")
    func malformedItemSkippedNotWholeList() throws {
        let json = """
        { "content": [
          { "id": "ok-1", "modality": "IMAGE", "createdAt": "2026-09-23T09:00:00Z",
            "imageDetection": { "model": "spai", "score": 0.1 } },
          { "id": "no-created-at", "modality": "IMAGE", "imageDetection": { "model": "spai", "score": 0.1 } },
          { "id": "bad-video", "modality": "VIDEO", "createdAt": "2026-09-23T08:00:00Z",
            "videoDetection": { "model": "dfdc", "score": 0.9 } },
          { "id": "ok-2", "modality": "VIDEO", "createdAt": "2026-09-23T07:00:00Z",
            "videoDetection": { "model": "dfdc", "score": 0.9, "evidence": [] } }
        ] }
        """
        let dto = try JSONDecoder().decode(AnalysisRecordsResponseDTO.self, from: Data(json.utf8))
        #expect(dto.content.map(\.id) == ["ok-1", "ok-2"])
    }

    /// 계약상 `content` 는 required · non-null 이다. 조용히 빈 목록으로 받으면 "기록 없음"이라는 거짓 문장이 된다.
    @Test("content 키가 없거나 null 이거나 이름이 바뀌면 디코딩 오류다", arguments: [
        "{}",
        #"{ "content": null }"#,
        #"{ "records": [ { "id": "a", "modality": "IMAGE", "createdAt": "2026-09-23T09:00:00Z" } ] }"#,
    ])
    func missingContentThrows(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AnalysisRecordsResponseDTO.self, from: Data(json.utf8))
        }
    }

    @Test("content: [] 는 정상적인 빈 목록이다")
    func emptyContentIsEmptyList() throws {
        let dto = try JSONDecoder().decode(AnalysisRecordsResponseDTO.self, from: Data(#"{ "content": [] }"#.utf8))
        #expect(dto.content.isEmpty)
    }

    /// 형태가 통째로 어긋나면(추론한 `videoDetection` 형태가 틀린 경우 등) 전 항목이 실패한다 — 오류로 올린다.
    @Test("항목이 전부 디코딩에 실패하면 빈 목록이 아니라 오류다")
    func allItemsInvalidThrows() {
        let json = """
        { "content": [
          { "id": 1, "modality": "IMAGE", "createdAt": "2026-09-23T09:00:00Z" },
          { "id": "v", "modality": "VIDEO", "createdAt": "2026-09-23T08:00:00Z", "videoDetection": { "model": "dfdc", "score": 0.9 } }
        ] }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AnalysisRecordsResponseDTO.self, from: Data(json.utf8))
        }
    }

    /// 디코딩은 성공했지만 매핑에서 전부 빠지는 경우(서버가 modality 를 소문자로 보내는 등)도 오류다.
    @Test("항목이 전부 미지 modality 면 매핑이 오류를 던진다")
    func allUnknownModalityThrows() throws {
        let json = """
        { "content": [
          { "id": "a", "modality": "image", "createdAt": "2026-09-23T09:00:00Z", "imageDetection": { "model": "spai", "score": 0.1 } },
          { "id": "b", "modality": "audio", "createdAt": "2026-09-23T08:00:00Z" }
        ] }
        """
        let dto = try JSONDecoder().decode(AnalysisRecordsResponseDTO.self, from: Data(json.utf8))
        #expect(dto.content.count == 2)
        #expect(throws: AuthAPIError.self) {
            try AnalysisHistoryStore.mapped(dto.content)
        }
        // 빈 입력은 오류가 아니다 — 정말로 기록이 없는 것이다.
        #expect(try AnalysisHistoryStore.mapped([]).isEmpty)
    }

    @Test("createdAt 은 RFC 3339(소수 초 포함)를 읽고, 실패하면 크래시 없이 nil 로 떨어진다")
    func createdAtParsing() throws {
        let records = try mapped()
        #expect(records[0].date == Date(timeIntervalSince1970: 1_790_154_000))  // 2026-09-23T09:00:00Z
        #expect(records[3].date == nil)                                           // "어제 오후"
        #expect(records[4].date != nil)                                           // 소수 초
    }
}

/// 사기 위험도는 AI 게이지와 **같은 임계값**을 쓴다 — 한 화면의 두 "높음"이 같은 뜻이어야 한다.
@Suite("위험도 구간")
@MainActor
struct RiskLevelThresholdTests {

    /// 두 매핑 경로(AI 점수 → `aiLevel`, 사기 점수 → `riskLevel`)가 **각각** 명세된 경계(0.35 / 0.7)에서
    /// 단계를 바꾸는지 리터럴 기대값으로 고정한다. 어느 한쪽이 다른 임계값(예: 리포트의 0.5)으로 바뀌면 깨진다.
    @Test("AI·사기 두 경로가 같은 경계에서 단계를 바꾼다", arguments: [
        (0.0, RiskLevel.low), (0.3499, .low), (0.35, .medium), (0.5, .medium),
        (0.6999, .medium), (0.7, .high), (1.0, .high),
    ])
    func bothPathsShareBoundaries(score: Double, expected: RiskLevel) {
        let record = AnalysisRecord(
            modality: .audio,
            input: nil,
            ai: AIDetectionParts(model: "antideepfake", score: score, evidence: [], evidenceImageBase64: nil),
            scam: ScamDetectionDTO(model: "lilju", score: score, evidence: nil)
        )
        #expect(record.aiLevel == expected)
        #expect(record.riskLevel == expected)
    }

    @Test("경계값: 0.35 는 보통, 0.7 은 높음")
    func boundaries() {
        #expect(RiskLevel(score: 0.3499) == .low)
        #expect(RiskLevel(score: 0.35) == .medium)
        #expect(RiskLevel(score: 0.6999) == .medium)
        #expect(RiskLevel(score: 0.7) == .high)
    }

    /// AI 판독 근거와 달리 사기 근거 문장은 서버가 문장별 점수를 준다 — 같은 구간으로 옮긴다.
    @Test("사기 근거 문장의 severity 는 서버 문장 점수에서 온다")
    func scamEvidenceSeverity() {
        let item = EvidenceItem(scam: ScamEvidenceDTO(sentence: "지금 송금하세요.", score: 0.95))
        #expect(item.title == "지금 송금하세요.")
        #expect(item.severity == .high)
        #expect(item.timeRange == nil)
    }
}
