import Foundation
import Observation

/// 분석 실행을 담당하는 스토어. 입력 검증 → 업로드 → (영상) 폴링 → `AnalysisRecord` 매핑.
///
/// `AppState`가 소유한다 — 모달(`AnalysisFlowView`)이 소유하면 사용자가 화면을 닫는 순간
/// 진행 중인 영상 `jobId`가 사라진다. 서버 작업은 계속 돌고 있으므로 그걸 잃으면 결과를
/// 영원히 못 받는다.
///
/// `phase` 전환만 발행하고 기록 보관은 하지 않는다 — 기록의 정본은 서버이고, 목록은
/// `AnalysisHistoryStore` 가 불러온다(ADR-0017).
@MainActor
@Observable
final class AnalysisStore {

    /// 진행 단계. 기존 `AnalyzingView`는 문구를 타이머로 돌려 **실제 진행과 무관한** 가짜
    /// 단계를 보여줬다 — 실제 상태를 발행해 그걸 대체한다.
    enum Stage: Equatable {
        case preparing
        case uploading
        case analyzing
        /// 영상 job이 서버 큐에 있음 (PENDING).
        case queued
        /// 영상 job 처리 중 (PROCESSING).
        case processing

        var label: String {
            switch self {
            case .preparing: "파일을 준비하고 있습니다…"
            case .uploading: "업로드 중…"
            case .analyzing: "AI 생성 여부를 분석하고 있습니다…"
            case .queued: "분석 대기 중…"
            case .processing: "영상을 분석하고 있습니다…"
            }
        }
    }

    enum Phase {
        case running(Stage)
        case finished(AnalysisRecord)
        case failed(AnalysisError)
    }

    private(set) var phase: Phase = .running(.preparing)

    /// 진행 중인 영상 job. 모달을 닫아도 남겨 두어 재진입 시 이어서 폴링한다.
    ///
    /// **앱을 재시작하면 사라진다.** 영속화는 기록 목록 화면과 함께 다뤄야 해서 이번 범위 밖이다.
    private(set) var pendingVideoJob: (id: String, input: AnalysisInput)?

    private let api: AnalysisAPI
    private let authStore: AuthStore

    init(api: AnalysisAPI, authStore: AuthStore) {
        self.api = api
        self.authStore = authStore
    }

    // MARK: - 실행

    func analyze(_ input: AnalysisInput) async {
        phase = .running(.preparing)

        guard let file = input.file else {
            // 링크 입력은 대응 엔드포인트가 없다. 이 경로는 UI에서 이미 막혀 있어야 하지만,
            // 스토어가 스스로 방어해 목/실 구현과 무관하게 같은 문구를 낸다.
            phase = .failed(.unsupportedInput("링크 분석은 아직 지원하지 않습니다."))
            return
        }
        if let hint = UploadRule.submitBlockingHint(for: file) {
            phase = .failed(.unsupportedInput(hint))
            return
        }

        do {
            switch file.kind {
            case .image:
                phase = .running(.uploading)
                let dto = try await authStore.withValidAccessToken { [api] token in
                    try await api.analyzeImage(file, accessToken: token)
                }
                phase = .finished(
                    AnalysisRecord(
                        modality: .image,
                        input: input,
                        ai: AIDetectionParts(dto.aiDetection),
                        scam: dto.scamDetection
                    )
                )

            case .audio:
                phase = .running(.uploading)
                let dto = try await authStore.withValidAccessToken { [api] token in
                    try await api.analyzeAudio(file, accessToken: token)
                }
                phase = .finished(
                    AnalysisRecord(
                        modality: .audio,
                        input: input,
                        ai: AIDetectionParts(dto.aiDetection),
                        scam: dto.scamDetection
                    )
                )

            case .video:
                phase = .running(.uploading)
                let jobID = try await authStore.withValidAccessToken { [api] token in
                    try await api.submitVideo(file, accessToken: token)
                }
                pendingVideoJob = (id: jobID, input: input)
                await pollVideoJob(id: jobID, input: input)
            }
        } catch {
            phase = .failed(Self.mapped(error))
        }
    }

    /// 모달 재진입 시 진행 중이던 영상 job을 이어서 폴링한다.
    func resumePendingVideoJobIfNeeded() async {
        guard let pending = pendingVideoJob else { return }
        phase = .running(.processing)
        await pollVideoJob(id: pending.id, input: pending.input)
    }

    // MARK: - 영상 폴링

    /// 서버 상한(`detection.video-read-timeout=20m`)과 같은 값을 쓴다. **클라가 서버보다 먼저
    /// 포기하면 서버는 멀쩡히 분석을 끝냈는데 앱만 실패를 표시한다** — 가짜 실패를 만들지
    /// 않으려면 클라 상한이 서버 상한보다 짧아서는 안 된다. 실제 소요 시간 실측치가 없어
    /// (서버 `application.properties`에도 "실측 데이터 없음") 상한을 좁힐 근거가 아직 없다.
    /// 사용자는 그전에 언제든 모달을 닫을 수 있고, 그래도 job은 남는다.
    private static let videoPollTimeout: TimeInterval = 20 * 60
    private static let initialPollInterval: TimeInterval = 2
    private static let maxPollInterval: TimeInterval = 10
    private static let pollBackoffFactor: Double = 1.5

    private func pollVideoJob(id: String, input: AnalysisInput) async {
        let deadline = Date.now.addingTimeInterval(Self.videoPollTimeout)
        var interval = Self.initialPollInterval

        while Date.now < deadline {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                // 취소 — 모달이 닫힌 것이다. job은 남겨 두고 조용히 빠진다.
                return
            }

            let dto: AnalysisJobDTO
            do {
                dto = try await authStore.withValidAccessToken { [api] token in
                    try await api.job(id: id, accessToken: token)
                }
            } catch {
                let mapped = Self.mapped(error)
                if case .jobNotFound = mapped {
                    // 작업이 사라졌다 — 폴링을 계속할 근거가 없으므로 상태를 폐기한다.
                    pendingVideoJob = nil
                }
                phase = .failed(mapped)
                return
            }

            // `status`는 `String`이다 — 미지 값은 "아직 처리 중"으로 폴백해 폴링을 계속한다.
            // 닫힌 enum이었다면 서버가 상태를 하나 추가하는 순간 디코딩부터 깨진다.
            switch AnalysisJobStatusCode(rawValue: dto.status) {
            case .completed:
                pendingVideoJob = nil
                phase = Self.completedPhase(for: dto, input: input)
                return

            case .failed:
                pendingVideoJob = nil
                phase = .failed(Self.failure(for: dto))
                return

            case .pending:
                phase = .running(.queued)
            case .processing, .none:
                phase = .running(.processing)
            }

            interval = min(interval * Self.pollBackoffFactor, Self.maxPollInterval)
        }

        phase = .failed(.unknown("분석이 예상보다 오래 걸리고 있습니다. 잠시 후 다시 확인해 주세요."))
    }

    // MARK: - 매핑

    /// `COMPLETED` job → 결과 화면. **`status` 를 먼저 보고, 그다음 `aiDetection`/`scamDetection` 을
    /// 각각 존재 여부로 판단한다**(서버 명시). `errorCode` 가 있어도 `COMPLETED` 면 실패가 아니다 —
    /// `NO_FACE_DETECTED` 는 AI 판독만 빠진 정상 결과다. 분기는 `errorCode`/필드 존재로만 하고
    /// `errorMessage` 문자열로는 하지 않는다(ADR-0018).
    ///
    /// 유일한 실패 경우: **둘 다 없고 사유(`errorCode`)도 없는** `COMPLETED`. 보여줄 것도, 비어 있는
    /// 이유도 없어 계약 위반으로 본다 — 빈 결과 화면으로 성공을 위장하지 않는다.
    /// 사유가 있으면(얼굴 없음 + 발화 없음처럼 둘 다 정상적으로 빈 영상) 사유 문구만 있는 결과로 끝낸다.
    static func completedPhase(for dto: AnalysisJobDTO, input: AnalysisInput) -> Phase {
        if dto.aiDetection == nil, dto.scamDetection == nil, dto.errorCode == nil {
            return .failed(.server)
        }
        return .finished(
            AnalysisRecord(
                modality: .video,
                input: input,
                ai: dto.aiDetection.map { AIDetectionParts($0) },
                scam: dto.scamDetection,
                errorCode: dto.errorCode,
                serverNotice: dto.errorMessage
            )
        )
    }

    /// `FAILED` job → 오류. 서버 `errorMessage` 를 그대로 보여준다.
    ///
    /// 재시도 여부는 `errorCode` 로만 정한다. `ANALYSIS_FAILED` 는 명세상 "같은 영상으로 재시도 가능"
    /// 이라 기존 실패 화면의 "다시 시도"(같은 입력으로 재접수)를 연다. 미지·부재 코드는 재시도로
    /// 해결되는지 알 수 없어 열지 않는다(열린 집합 — 모르는 것을 약속하지 않는다).
    static func failure(for dto: AnalysisJobDTO) -> AnalysisError {
        let retryable = dto.errorCode.flatMap(AnalysisOutcomeCode.init(rawValue:)) == .analysisFailed
        return .jobFailed(dto.errorMessage ?? "영상 분석에 실패했습니다.", retryable: retryable)
    }

    static func mapped(_ error: Error) -> AnalysisError {
        switch error {
        case let apiError as AuthAPIError:
            AnalysisError(apiError: apiError)
        case is AuthSessionError:
            // 저장된 토큰이 없다 — 세션이 끊긴 것이다.
            .sessionExpired
        case is TokenStoreError:
            .sessionExpired
        case is CancellationError:
            .network
        default:
            .server
        }
    }
}

// MARK: - DTO → AnalysisRecord

/// 모달리티별 AI 판독 DTO 3종(image/audio/video)의 공통 부분. 분석 응답과 기록 항목이 같은
/// 스키마를 서로 다른 키 이름으로 주므로, 매핑을 한 곳으로 모으기 위해 여기서 한 번 평탄화한다.
struct AIDetectionParts {
    let model: String
    let score: Double
    let evidence: [EvidenceDTO]
    let evidenceImageBase64: String?

    init(_ dto: ImageDetectionDTO) {
        self.init(model: dto.model, score: dto.score, evidence: [], evidenceImageBase64: dto.evidenceImage)
    }

    init(_ dto: AudioDetectionDTO) {
        self.init(model: dto.model, score: dto.score, evidence: dto.evidence, evidenceImageBase64: nil)
    }

    init(_ dto: VideoDetectionDTO) {
        self.init(model: dto.model, score: dto.score, evidence: dto.evidence, evidenceImageBase64: dto.evidenceImage)
    }

    init(model: String, score: Double, evidence: [EvidenceDTO], evidenceImageBase64: String?) {
        self.model = model
        self.score = score
        self.evidence = evidence
        self.evidenceImageBase64 = evidenceImageBase64
    }
}

extension AnalysisRecord {
    /// 분석 응답·기록 항목 공통 매핑. 방금 끝난 분석(`input` 있음)과 서버 기록(`input == nil`)이 같은 경로를 탄다.
    ///
    /// - `ai == nil`: AI 판독 없음 → `aiProbability == nil`, 사유 문구를 `notice` 로(ADR-0018).
    /// - `scam == nil`: 키 부재 → `riskLevel == nil`, 카드 숨김(이유는 말하지 않는다 — 영상은 의미 미확정).
    init(
        id: String = UUID().uuidString,
        date: Date? = .now,
        modality: UploadFile.Kind,
        input: AnalysisInput?,
        ai: AIDetectionParts?,
        scam: ScamDetectionDTO?,
        errorCode: String? = nil,
        serverNotice: String? = nil
    ) {
        self.init(
            id: id,
            date: date,
            modality: modality,
            input: input,
            aiProbability: ai?.score,
            summary: ai.map { Self.summary(for: $0.score) },
            aiEvidence: (ai?.evidence ?? []).map { EvidenceItem(dto: $0) },
            model: ai?.model,
            evidenceImage: ai?.evidenceImageBase64.flatMap { Data(base64Encoded: $0) },
            riskLevel: scam.map { RiskLevel(score: $0.score) },
            riskEvidence: (scam?.evidence ?? []).map { EvidenceItem(scam: $0) },
            notice: serverNotice ?? (ai == nil ? Self.missingAINotice(errorCode: errorCode) : nil)
        )
    }

    /// 서버 기록 항목 → `AnalysisRecord`. **미지 `modality` 면 `nil`** — 호출자가 목록에서 건너뛴다.
    /// 어느 detection 필드를 읽을지는 `modality` 가 정한다(서버 명시). 나머지 두 필드는 보지 않는다.
    init?(server dto: AnalysisRecordDTO) {
        guard let code = AnalysisModalityCode(rawValue: dto.modality) else { return nil }
        let modality: UploadFile.Kind
        let ai: AIDetectionParts?
        switch code {
        case .image:
            modality = .image
            ai = dto.imageDetection.map { AIDetectionParts($0) }
        case .audio:
            modality = .audio
            ai = dto.audioDetection.map { AIDetectionParts($0) }
        case .video:
            modality = .video
            ai = dto.videoDetection.map { AIDetectionParts($0) }
        }
        self.init(
            id: dto.id,
            date: Self.parseServerDate(dto.createdAt),
            modality: modality,
            input: nil,
            ai: ai,
            scam: dto.scamDetection,
            errorCode: dto.errorCode,
            // 기록 항목에는 `errorMessage` 가 없다 — 사유 문구는 `errorCode` 에서 고른다.
            serverNotice: nil
        )
    }

    /// RFC 3339(소수 초 유무 모두). 실패하면 `nil` — 표시만 "날짜 알 수 없음"으로 바뀐다.
    /// `ISO8601DateFormatter` 는 소수 초 옵션 유무에 따라 **한쪽 형식만** 받는다(실측) — Spring 의
    /// `Instant` 는 소수 초를 붙여 직렬화하는 경우가 흔해서 둘 다 받는 파서를 쓴다.
    static func parseServerDate(_ raw: String) -> Date? {
        try? Date(raw, strategy: .iso8601)
    }

    /// AI 판독이 비었는데 서버 문구가 없을 때(기록 항목, 또는 job 이 문구를 빼먹은 경우)의 안내.
    /// `errorCode` 로만 고른다 — 미지 코드는 일반 문구로 떨어진다.
    static func missingAINotice(errorCode: String?) -> String {
        switch errorCode.flatMap(AnalysisOutcomeCode.init(rawValue:)) {
        case .noFaceDetected:
            "영상에서 얼굴을 찾지 못해 AI 판독은 제공되지 않았습니다."
        case .analysisFailed, .none:
            "이 분석에는 AI 판독 결과가 없습니다."
        }
    }

    /// 서버는 요약 문구를 주지 않는다. `score` 구간에서 확실히 말할 수 있는 것만 쓰고,
    /// 출처·유포 이력처럼 **서버가 판단하지 않은 것은 쓰지 않는다.**
    private static func summary(for score: Double) -> String {
        switch RiskLevel(score: score) {
        case .low:
            "AI로 생성된 흔적이 뚜렷하지 않습니다. 다만 이 결과만으로 진위를 단정할 수는 없습니다."
        case .medium:
            "판단이 어려운 구간입니다. AI 생성 가능성을 배제할 수 없으니 출처를 함께 확인해 주세요."
        case .high:
            "AI로 생성되었을 가능성이 높습니다. 공유하거나 신뢰하기 전에 출처를 확인해 주세요."
        }
    }
}

extension EvidenceItem {
    /// 서버 `scamDetection.evidence[]` → UI 근거 항목.
    ///
    /// `severity` 를 채운다 — AI 판독 근거와 달리 **서버가 문장별 `score` 를 준다.** 지어낸 값이 아니다.
    /// 구간 정보는 없다(`timeRange == nil`).
    init(scam dto: ScamEvidenceDTO) {
        self.init(
            icon: "text.quote",
            title: dto.sentence,
            detail: dto.sentence,
            severity: RiskLevel(score: dto.score),
            timeRange: nil
        )
    }

    /// 서버 `Evidence` → UI 근거 항목.
    ///
    /// `severity`는 항상 `nil`이다 — 서버가 심각도를 주지 않으므로 전체 점수에서 역산해
    /// 붙이지 않는다(그건 서버가 말하지 않은 것을 지어내는 것이다).
    init(dto: EvidenceDTO) {
        self.init(
            icon: Self.icon(for: dto.tags),
            title: dto.title,
            detail: Self.detailWithTimeRange(dto),
            severity: nil,
            timeRange: dto.endSec > dto.startSec ? dto.startSec...dto.endSec : nil
        )
    }

    private static func icon(for tags: [String]) -> String {
        for tag in tags {
            switch tag {
            case "temporal": return "waveform.path.ecg"
            case "spatial": return "square.grid.3x3"
            case "spectral": return "waveform"
            default: continue
            }
        }
        return "doc.text.magnifyingglass"
    }

    /// 근거 구간을 본문에 덧붙인다. 서버 `description`이 이미 구간을 언급하는 경우가 있어
    /// 중복되지만, 구간 정보를 버리는 것보다는 낫다 — UI에 구간 전용 표시 자리가 없다.
    private static func detailWithTimeRange(_ dto: EvidenceDTO) -> String {
        guard dto.endSec > dto.startSec else { return dto.description }
        let range = String(format: "%.1f초~%.1f초", dto.startSec, dto.endSec)
        return "\(dto.description)\n구간: \(range)"
    }
}
