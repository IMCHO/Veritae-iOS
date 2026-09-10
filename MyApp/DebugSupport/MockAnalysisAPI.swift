import Foundation

#if DEBUG

/// 서버 계약대로 동작하는 목 `AnalysisAPI`. 탐지 서버 미배포 상태에서 개발/QA를 진행하기 위함
/// (ADR-0001). `-UseMockAnalysisAPI 1` 런치 인자로 전환하고, `-MockAnalysisScenario <case>`로
/// 오류 케이스를 재현한다.
///
/// **목을 API 계층에 두는 것이 중요하다.** 기존 `AnalysisEngine`은 UI 모델(`AnalysisRecord`)을
/// 통째로 만들어내서, 목으로 돌리면 DTO 디코딩·오류 매핑·폴링 경로가 **전혀 실행되지 않았다.**
/// 목에서 잘 되다가 서버를 붙이는 순간 처음 깨지는 구조다(LL-001이 기록한 "목에서만 재현되는
/// 버그"와 같은 함정). 서버와 동일한 DTO를 반환하게 두면 그 경로 전체가 목에서도 돈다.
///
/// **DEBUG 전용이다.** Release에 남으면 실제 분석 없이 판정을 만들어내는 경로가 된다.
struct MockAnalysisAPI: AnalysisAPI {
    enum Scenario: String, Sendable {
        /// 400 INVALID_*_FILE — 스펙에 없는 errorCode 경로 재현(불일치 보고서 M2)
        case invalidFile
        /// 502 DETECTION_SERVICE_UNAVAILABLE
        case detectionUnavailable
        /// 401 UNAUTHORIZED (매번 — refresh 후에도 실패해 AC-11 재현)
        case unauthorized
        /// 500 INTERNAL_SERVER_ERROR
        case serverError
        /// 404 ANALYSIS_JOB_NOT_FOUND — job 폴링 중 소실
        case jobNotFound
        /// 영상 job이 FAILED + "얼굴 없음" errorMessage
        case videoNoFace
        /// 스펙에 **없는** errorCode를 발행 — 닫힌 enum 디코딩이었다면 깨졌을 경로(M3) 재현
        case undocumentedErrorCode
    }

    let scenario: Scenario?
    private let jobs = MockJobStore()

    init(scenario: Scenario? = nil) {
        self.scenario = scenario
    }

    nonisolated func analyzeImage(_ file: UploadFile, accessToken: String) async throws -> ImageDetectionDTO {
        try await Task.sleep(for: .seconds(1.6))
        try check(instance: "/api/v1/analysis/image", invalidCode: .invalidImageFile)
        // SPAI는 근거 카드를 만들지 않는다 — evidence 필드 자체가 없다(M1).
        return ImageDetectionDTO(model: "spai", score: Self.pseudoScore(for: file), evidenceImage: nil)
    }

    nonisolated func analyzeAudio(_ file: UploadFile, accessToken: String) async throws -> AudioDetectionDTO {
        try await Task.sleep(for: .seconds(2.2))
        try check(instance: "/api/v1/analysis/audio", invalidCode: .invalidAudioFile)
        let score = Self.pseudoScore(for: file)
        return AudioDetectionDTO(
            model: "antideepfake",
            score: score,
            evidence: score > 0.5 ? Self.sampleEvidence : []
        )
    }

    nonisolated func submitVideo(_ file: UploadFile, accessToken: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        try check(instance: "/api/v1/analysis/video", invalidCode: .invalidVideoFile)
        return await jobs.create(score: Self.pseudoScore(for: file))
    }

    nonisolated func job(id: String, accessToken: String) async throws -> AnalysisJobDTO {
        try await Task.sleep(for: .milliseconds(250))
        if scenario == .unauthorized {
            throw Self.problem(
                status: 401,
                errorCode: KnownErrorCode.unauthorized.rawValue,
                title: "Unauthorized",
                detail: "액세스 토큰이 유효하지 않습니다.",
                instance: "/api/v1/analysis/jobs/\(id)"
            )
        }
        if scenario == .jobNotFound {
            throw Self.problem(
                status: 404,
                errorCode: AnalysisErrorCode.analysisJobNotFound.rawValue,
                title: "Analysis Job Not Found",
                detail: "분석 작업을 찾을 수 없습니다.",
                instance: "/api/v1/analysis/jobs/\(id)"
            )
        }
        guard let dto = await jobs.snapshot(id: id, failWithNoFace: scenario == .videoNoFace) else {
            throw Self.problem(
                status: 404,
                errorCode: AnalysisErrorCode.analysisJobNotFound.rawValue,
                title: "Analysis Job Not Found",
                detail: "분석 작업을 찾을 수 없습니다.",
                instance: "/api/v1/analysis/jobs/\(id)"
            )
        }
        return dto
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
            throw Self.problem(
                status: 401,
                errorCode: KnownErrorCode.unauthorized.rawValue,
                title: "Unauthorized",
                detail: "액세스 토큰이 유효하지 않습니다.",
                instance: instance
            )
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
            // 서버 `handleExceptionInternal`이 실제로 발행하는 형태 — `HttpStatus` 이름(M3).
            // 닫힌 enum으로 디코딩했다면 여기서 오류 본문 전체를 잃는다.
            throw Self.problem(
                status: 415,
                errorCode: "UNSUPPORTED_MEDIA_TYPE",
                title: "Unsupported Media Type",
                detail: "지원하지 않는 미디어 타입입니다.",
                instance: instance
            )
        case .jobNotFound, .videoNoFace, .none:
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
    }

    private var jobs: [String: Job] = [:]

    func create(score: Double) -> String {
        let id = UUID().uuidString
        jobs[id] = Job(createdAt: .now, score: score)
        return id
    }

    func snapshot(id: String, failWithNoFace: Bool) -> AnalysisJobDTO? {
        guard let job = jobs[id] else { return nil }
        let elapsed = Date.now.timeIntervalSince(job.createdAt)

        if failWithNoFace, elapsed > 4 {
            return AnalysisJobDTO(
                jobId: id,
                status: AnalysisJobStatusCode.failed.rawValue,
                aiDetection: nil,
                errorMessage: "영상에서 얼굴을 찾을 수 없습니다. 얼굴이 잘 보이는 영상으로 다시 시도해주세요."
            )
        }
        if elapsed < 1.5 {
            return AnalysisJobDTO(
                jobId: id,
                status: AnalysisJobStatusCode.pending.rawValue,
                aiDetection: nil,
                errorMessage: nil
            )
        }
        if elapsed < 5 {
            return AnalysisJobDTO(
                jobId: id,
                status: AnalysisJobStatusCode.processing.rawValue,
                aiDetection: nil,
                errorMessage: nil
            )
        }
        return AnalysisJobDTO(
            jobId: id,
            status: AnalysisJobStatusCode.completed.rawValue,
            aiDetection: VideoDetectionDTO(
                model: "dfdc",
                score: job.score,
                evidence: job.score > 0.5 ? Self.videoEvidence : [],
                evidenceImage: nil
            ),
            errorMessage: nil
        )
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

#endif
