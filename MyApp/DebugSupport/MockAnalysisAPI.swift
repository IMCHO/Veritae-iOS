import Foundation
import UIKit

#if DEBUG

/// 서버 계약(2026-09-24 명세)대로 동작하는 목 `AnalysisAPI`. 탐지 서버 미배포 상태에서 개발/QA를
/// 진행하기 위함(ADR-0001). `-UseMockAnalysisAPI 1` 런치 인자로 전환하고, `-MockAnalysisScenario <case>`로
/// 오류·부분 결과 케이스를 재현한다.
///
/// **목을 API 계층에 두는 것이 중요하다.** 기존 `AnalysisEngine`은 UI 모델(`AnalysisRecord`)을
/// 통째로 만들어내서, 목으로 돌리면 DTO 디코딩·오류 매핑·폴링 경로가 **전혀 실행되지 않았다.**
/// 목에서 잘 되다가 서버를 붙이는 순간 처음 깨지는 구조다(LL-001이 기록한 "목에서만 재현되는
/// 버그"와 같은 함정). 서버와 동일한 DTO를 반환하게 두면 그 경로 전체가 목에서도 돈다.
///
/// **DEBUG 전용이다.** Release에 남으면 실제 분석 없이 판정을 만들어내는 경로가 된다.
struct MockAnalysisAPI: AnalysisAPI {
    enum Scenario: String, Sendable {
        /// 400 INVALID_*_FILE
        case invalidFile
        /// 502 DETECTION_SERVICE_UNAVAILABLE (image/audio 에서는 AI 탐지·사기감지 실패 둘 다 이 코드)
        case detectionUnavailable
        /// 401 UNAUTHORIZED (매번 — refresh 후에도 실패해 AC-11 재현)
        case unauthorized
        /// 500 INTERNAL_SERVER_ERROR
        case serverError
        /// 404 ANALYSIS_JOB_NOT_FOUND — job 폴링 중 소실
        case jobNotFound
        /// 영상 job 이 **COMPLETED** + `NO_FACE_DETECTED` — AI 판독 없이 사기 탐지만 온다(부분 결과).
        /// 2026-09-24 명세 이전에는 FAILED + errorMessage 였다. 런치 인자 이름은 유지한다.
        case videoNoFace
        /// 영상 job 이 FAILED + `ANALYSIS_FAILED` — 같은 영상으로 재시도 가능한 처리 실패.
        case videoFailed
        /// `scamDetection` 키를 뺀다 — 사기 위험도 카드 숨김 경로. image/audio 에서는 "텍스트 없음"이
        /// 확정된 의미이고, 영상은 명세가 의미를 적지 않았다(계약 확인 항목 17).
        case noScamText
        /// 스펙 표에 **없는** errorCode(프레임워크 레벨 `HttpStatus` 이름)를 발행 — 열린 집합 처리 재현
        case undocumentedErrorCode
    }

    let scenario: Scenario?
    private let jobs = MockJobStore()
    /// 목 기록 목록. 분석이 끝날 때마다 앞에 쌓인다 — "분석 후 계정 화면을 열면 방금 기록이 보인다"를
    /// 목에서도 확인할 수 있어야 한다.
    private let history = MockRecordStore()

    init(scenario: Scenario? = nil) {
        self.scenario = scenario
    }

    nonisolated func analyzeImage(_ file: UploadFile, accessToken: String) async throws -> ImageAnalysisResponseDTO {
        try await Task.sleep(for: .seconds(1.6))
        try check(instance: "/api/v1/analysis/image", invalidCode: .invalidImageFile)
        let score = Self.pseudoScore(for: file)
        // SPAI 는 근거 카드를 만들지 않는다 — evidence 필드 자체가 없다. 히트맵은 best-effort 라
        // 점수가 낮으면 빼서 "히트맵 없음" 경로도 목에서 돌게 한다.
        let detection = ImageDetectionDTO(
            model: "spai",
            score: score,
            evidenceImage: score > 0.5 ? MockHeatmap.base64PNG() : nil
        )
        let scam = scamDetection(for: file)
        await history.add(modality: .image, image: detection, scam: scam)
        return ImageAnalysisResponseDTO(aiDetection: detection, scamDetection: scam)
    }

    nonisolated func analyzeAudio(_ file: UploadFile, accessToken: String) async throws -> AudioAnalysisResponseDTO {
        try await Task.sleep(for: .seconds(2.2))
        try check(instance: "/api/v1/analysis/audio", invalidCode: .invalidAudioFile)
        let detection = AudioDetectionDTO(
            model: "antideepfake",
            score: Self.pseudoScore(for: file),
            // 점수와 무관하게 구간을 준다 — 서버도 낮은 점수에서 짧은 구간을 낼 수 있고,
            // 목에서 타임라인·파형 강조 경로가 항상 실행돼야 QA 가 볼 수 있다.
            evidence: Self.sampleEvidence
        )
        let scam = scamDetection(for: file)
        await history.add(modality: .audio, audio: detection, scam: scam)
        return AudioAnalysisResponseDTO(aiDetection: detection, scamDetection: scam)
    }

    nonisolated func submitVideo(_ file: UploadFile, accessToken: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        try check(instance: "/api/v1/analysis/video", invalidCode: .invalidVideoFile)
        return await jobs.create(score: Self.pseudoScore(for: file), scam: scamDetection(for: file))
    }

    nonisolated func job(id: String, accessToken: String) async throws -> AnalysisJobDTO {
        try await Task.sleep(for: .milliseconds(250))
        if scenario == .unauthorized {
            throw Self.unauthorized(instance: "/api/v1/analysis/jobs/\(id)")
        }
        if scenario == .jobNotFound {
            throw Self.jobNotFound(id: id)
        }
        guard let dto = await jobs.snapshot(id: id, scenario: scenario) else {
            throw Self.jobNotFound(id: id)
        }
        if dto.status == AnalysisJobStatusCode.completed.rawValue {
            await history.addVideoIfNeeded(jobID: id, job: dto)
        }
        return dto
    }

    nonisolated func records(accessToken: String) async throws -> [AnalysisRecordDTO] {
        try await Task.sleep(for: .milliseconds(500))
        try checkRead(instance: "/api/v1/analysis/records")
        return await history.list()
    }

    /// 명세 예시 그대로. 기록 목록(최대 10건)과 맞추지 않는다 — 서버도 통계는 **전체** 완료분을 센다.
    nonisolated func report(accessToken: String) async throws -> AnalysisReportDTO {
        try await Task.sleep(for: .milliseconds(400))
        try checkRead(instance: "/api/v1/analysis/report")
        return AnalysisReportDTO(
            totalCount: 23,
            imageCount: 10,
            audioCount: 8,
            videoCount: 5,
            aiDetectedCount: 3,
            scamDetectedCount: 2
        )
    }

    // MARK: - 사기 탐지

    /// 파일 내용에 따라 결정적인 사기 점수. `noScamText` 시나리오면 키를 뺀다.
    private nonisolated func scamDetection(for file: UploadFile) -> ScamDetectionDTO? {
        guard scenario != .noScamText else { return nil }
        let score = (Self.pseudoScore(for: file) * 3).truncatingRemainder(dividingBy: 1)
        return Self.sampleScam(score: score)
    }

    nonisolated static func sampleScam(score: Double) -> ScamDetectionDTO {
        ScamDetectionDTO(
            model: "lilju",
            score: score,
            evidence: [
                ScamEvidenceDTO(sentence: "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", score: 0.95),
                ScamEvidenceDTO(sentence: "이 통화 내용은 다른 사람에게 말씀하시면 안 됩니다.", score: 0.41),
            ]
        )
    }

    // MARK: - 공통 오류 분기

    private nonisolated func check(instance: String, invalidCode: AnalysisErrorCode) throws {
        switch scenario {
        case .serverError:
            throw Self.problem(
                status: 500,
                errorCode: KnownErrorCode.internalServerError.rawValue,
                title: "Internal Server Error",
                detail: "서버에서 예상하지 못한 오류가 발생했습니다.",
                instance: instance
            )
        case .unauthorized:
            throw Self.unauthorized(instance: instance)
        case .invalidFile:
            throw Self.problem(
                status: 400,
                errorCode: invalidCode.rawValue,
                title: "Invalid File",
                detail: "지원하지 않는 파일 형식입니다: image/heic",
                instance: instance
            )
        case .detectionUnavailable:
            throw Self.problem(
                status: 502,
                errorCode: AnalysisErrorCode.detectionServiceUnavailable.rawValue,
                title: "Detection Service Unavailable",
                detail: "탐지 서버 호출에 실패했습니다.",
                instance: instance
            )
        case .undocumentedErrorCode:
            // 서버가 프레임워크 레벨 오류에 싣는 형태 — `HttpStatus` 이름(명세 13p).
            throw Self.problem(
                status: 415,
                errorCode: "UNSUPPORTED_MEDIA_TYPE",
                title: "Unsupported Media Type",
                detail: "지원하지 않는 미디어 타입입니다.",
                instance: instance
            )
        case .jobNotFound, .videoNoFace, .videoFailed, .noScamText, .none:
            return
        }
    }

    /// records / report 공통. 명세상 이 둘은 200 / 401 / 500 만 낸다.
    private nonisolated func checkRead(instance: String) throws {
        switch scenario {
        case .unauthorized:
            throw Self.unauthorized(instance: instance)
        case .serverError:
            throw Self.problem(
                status: 500,
                errorCode: KnownErrorCode.internalServerError.rawValue,
                title: "Internal Server Error",
                detail: "서버에서 예상하지 못한 오류가 발생했습니다.",
                instance: instance
            )
        default:
            return
        }
    }

    /// 파일 내용에 따라 결정적인 점수를 만든다 — `Double.random`을 쓰면 같은 파일이 매번 다른
    /// 결과를 내서 QA 재현이 불가능하다.
    private nonisolated static func pseudoScore(for file: UploadFile) -> Double {
        let seed = file.data.prefix(2048).reduce(0) { ($0 &+ Int($1)) % 9_973 }
        return Double(seed % 1_000) / 1_000
    }

    private nonisolated static let sampleEvidence = [
        EvidenceDTO(
            title: "시간 구간 이상 패턴",
            description: "0.5초~1.2초 구간에서 합성 흔적이 감지됨",
            tags: ["temporal"],
            startSec: 0.5,
            endSec: 1.2
        ),
        EvidenceDTO(
            title: "주파수 불연속",
            description: "2.4초 지점에서 스펙트럼이 급격히 끊김 — 이어붙인 흔적일 수 있음",
            tags: ["spectral"],
            startSec: 2.4,
            endSec: 3.0
        ),
    ]

    private nonisolated static func unauthorized(instance: String) -> AuthAPIError {
        problem(
            status: 401,
            errorCode: KnownErrorCode.unauthorized.rawValue,
            title: "Unauthorized",
            detail: "액세스 토큰이 유효하지 않습니다.",
            instance: instance
        )
    }

    private nonisolated static func jobNotFound(id: String) -> AuthAPIError {
        problem(
            status: 404,
            errorCode: AnalysisErrorCode.analysisJobNotFound.rawValue,
            title: "Analysis Job Not Found",
            detail: "분석 작업을 찾을 수 없습니다.",
            instance: "/api/v1/analysis/jobs/\(id)"
        )
    }

    private nonisolated static func problem(
        status: Int,
        errorCode: String,
        title: String,
        detail: String,
        instance: String
    ) -> AuthAPIError {
        let problemDetail = ProblemDetail(
            type: "https://api.veritae.app/errors/\(errorCode.lowercased().replacingOccurrences(of: "_", with: "-"))",
            title: title,
            status: status,
            detail: detail,
            instance: instance,
            errorCode: errorCode,
            timestamp: ISO8601DateFormatter().string(from: .now),
            violations: nil
        )
        return .problem(problemDetail, status: status)
    }
}

/// 목 영상 job의 상태 저장소. `MockAnalysisAPI`가 struct 라 가변 상태를 직접 못 들고 있어
/// actor로 분리한다.
///
/// 경과 시간으로 PENDING → PROCESSING → COMPLETED를 넘긴다 — 폴링 백오프가 실제로 여러 번
/// 돌아야 결과가 나오므로 클라이언트 폴링 로직이 목에서도 검증된다.
private actor MockJobStore {
    private struct Job {
        let createdAt: Date
        let score: Double
        let scam: ScamDetectionDTO?
    }

    private var jobs: [String: Job] = [:]

    func create(score: Double, scam: ScamDetectionDTO?) -> String {
        let id = UUID().uuidString
        jobs[id] = Job(createdAt: .now, score: score, scam: scam)
        return id
    }

    func snapshot(id: String, scenario: MockAnalysisAPI.Scenario?) -> AnalysisJobDTO? {
        guard let job = jobs[id] else { return nil }
        let elapsed = Date.now.timeIntervalSince(job.createdAt)

        if elapsed < 1.5 {
            return AnalysisJobDTO(
                jobId: id,
                status: AnalysisJobStatusCode.pending.rawValue,
                aiDetection: nil,
                scamDetection: nil,
                errorCode: nil,
                errorMessage: nil
            )
        }
        if elapsed < 5 {
            return AnalysisJobDTO(
                jobId: id,
                status: AnalysisJobStatusCode.processing.rawValue,
                aiDetection: nil,
                scamDetection: nil,
                errorCode: nil,
                errorMessage: nil
            )
        }

        switch scenario {
        case .videoFailed:
            // 명세 8번 "완전 실패" 예시 그대로 — AI 판독·사기 탐지 둘 다 없다.
            return AnalysisJobDTO(
                jobId: id,
                status: AnalysisJobStatusCode.failed.rawValue,
                aiDetection: nil,
                scamDetection: nil,
                errorCode: AnalysisOutcomeCode.analysisFailed.rawValue,
                errorMessage: "영상 분석 중 오류가 발생했습니다."
            )
        case .videoNoFace:
            // 명세 8번 "얼굴 없음" 예시 그대로 — COMPLETED, aiDetection 키 없음, 사기 탐지는 있다.
            return AnalysisJobDTO(
                jobId: id,
                status: AnalysisJobStatusCode.completed.rawValue,
                aiDetection: nil,
                scamDetection: job.scam ?? MockAnalysisAPI.sampleScam(score: 0.82),
                errorCode: AnalysisOutcomeCode.noFaceDetected.rawValue,
                errorMessage: "영상에서 얼굴을 찾을 수 없어 AI판독은 제공되지 않습니다. 얼굴이 잘 보이는 영상이면 판독도 함께 받을 수 있습니다."
            )
        default:
            return AnalysisJobDTO(
                jobId: id,
                status: AnalysisJobStatusCode.completed.rawValue,
                aiDetection: VideoDetectionDTO(
                    model: "dfdc",
                    score: job.score,
                    evidence: Self.videoEvidence,
                    // 서버는 best-effort 로 Grad-CAM 히트맵을 합성한 PNG 를 준다. 목도 같은 모양의
                    // 이미지를 만들어 줘야 결과 화면의 오버레이 토글 경로가 목에서 실행된다.
                    evidenceImage: job.score > 0.5 ? MockHeatmap.base64PNG() : nil
                ),
                scamDetection: job.scam,
                errorCode: nil,
                errorMessage: nil
            )
        }
    }

    /// LL-002: `nonisolated`가 필수다. 무표기 `static let`은 MainActor로 격리 추론되고,
    /// 그러면 이 actor(nonisolated) 안에서 읽을 때 Swift 6에서 오류가 된다 — 실제로 이 파일을
    /// 처음 작성했을 때 여기서 걸렸다.
    private nonisolated static let videoEvidence = [
        EvidenceDTO(
            title: "얼굴 경계 불일치",
            description: "1.0초~2.5초 구간에서 얼굴 윤곽과 배경의 경계가 프레임마다 흔들림",
            tags: ["temporal", "spatial"],
            startSec: 1.0,
            endSec: 2.5
        ),
    ]
}

/// 목 기록 목록(`GET /analysis/records`). 명세 9번 예시 3건으로 시작하고, 목에서 끝난 분석을 앞에
/// 쌓는다. 서버처럼 **완료분만, 최신순, 최대 10건**이다.
private actor MockRecordStore {
    private static let limit = 10
    private var items: [AnalysisRecordDTO]?
    /// 폴링은 COMPLETED 를 여러 번 볼 수 있다 — 같은 job 을 두 번 쌓지 않는다.
    private var recordedJobIDs: Set<String> = []

    func list() -> [AnalysisRecordDTO] {
        seedIfNeeded()
        return items ?? []
    }

    func add(
        modality: AnalysisModalityCode,
        image: ImageDetectionDTO? = nil,
        audio: AudioDetectionDTO? = nil,
        video: VideoDetectionDTO? = nil,
        scam: ScamDetectionDTO?,
        errorCode: String? = nil
    ) {
        seedIfNeeded()
        let item = AnalysisRecordDTO(
            id: UUID().uuidString,
            modality: modality.rawValue,
            createdAt: ISO8601DateFormatter().string(from: .now),
            imageDetection: image,
            audioDetection: audio,
            videoDetection: video,
            scamDetection: scam,
            errorCode: errorCode
        )
        items = Array(([item] + (items ?? [])).prefix(Self.limit))
    }

    func addVideoIfNeeded(jobID: String, job: AnalysisJobDTO) {
        guard recordedJobIDs.insert(jobID).inserted else { return }
        add(modality: .video, video: job.aiDetection, scam: job.scamDetection, errorCode: job.errorCode)
    }

    /// 히트맵 렌더링이 있어 처음 조회할 때 만든다.
    private func seedIfNeeded() {
        guard items == nil else { return }
        items = [
            AnalysisRecordDTO(
                id: "11111111-1111-1111-1111-111111111111",
                modality: AnalysisModalityCode.image.rawValue,
                createdAt: "2026-09-23T09:00:00Z",
                imageDetection: ImageDetectionDTO(model: "spai", score: 0.87, evidenceImage: MockHeatmap.base64PNG()),
                audioDetection: nil,
                videoDetection: nil,
                scamDetection: nil,
                errorCode: nil
            ),
            AnalysisRecordDTO(
                id: "22222222-2222-2222-2222-222222222222",
                modality: AnalysisModalityCode.audio.rawValue,
                createdAt: "2026-09-23T08:30:00Z",
                imageDetection: nil,
                audioDetection: AudioDetectionDTO(
                    model: "antideepfake",
                    score: 0.73,
                    evidence: [
                        EvidenceDTO(
                            title: "합성 음성 의심 구간",
                            description: "1.0초~4.0초 구간에서 부자연스러운 음성 합성 흔적이 감지됨",
                            tags: ["temporal"],
                            startSec: 1.0,
                            endSec: 4.0
                        ),
                    ]
                ),
                videoDetection: nil,
                scamDetection: MockAnalysisAPI.sampleScam(score: 0.82),
                errorCode: nil
            ),
            AnalysisRecordDTO(
                id: "33333333-3333-3333-3333-333333333333",
                modality: AnalysisModalityCode.video.rawValue,
                createdAt: "2026-09-23T08:00:00Z",
                imageDetection: nil,
                audioDetection: nil,
                videoDetection: nil,
                scamDetection: MockAnalysisAPI.sampleScam(score: 0.82),
                errorCode: AnalysisOutcomeCode.noFaceDetected.rawValue
            ),
        ]
    }
}

/// 목 전용 합성 히트맵. 서버 `evidenceImage`(Grad-CAM 을 프레임 위에 합성한 PNG)와 같은 형태를
/// 흉내 낸다 — 어두운 프레임 위에 붉은 블롭 하나. 실제 판독 결과가 아니다.
private nonisolated enum MockHeatmap {
    static func base64PNG() -> String? {
        let size = CGSize(width: 640, height: 480)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(white: 0.16, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            // 얼굴 자리 — 밝은 타원
            cg.setFillColor(UIColor(red: 0.85, green: 0.76, blue: 0.69, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 240, y: 110, width: 160, height: 200))

            // 히트맵 블롭 — 붉은 중심에서 투명으로
            let colors = [
                UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 0.85).cgColor,
                UIColor(red: 1, green: 0.62, blue: 0.04, alpha: 0.55).cgColor,
                UIColor.clear.cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
                cg.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: 335, y: 190), startRadius: 0,
                    endCenter: CGPoint(x: 335, y: 190), endRadius: 95,
                    options: []
                )
            }
        }
        return image.pngData()?.base64EncodedString()
    }
}

#endif
