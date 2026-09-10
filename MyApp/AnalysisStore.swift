import Foundation
import Observation

/// 분석 실행을 담당하는 스토어. 입력 검증 → 업로드 → (영상) 폴링 → `AnalysisRecord` 매핑.
///
/// `AppState`가 소유한다 — 모달(`AnalysisFlowView`)이 소유하면 사용자가 화면을 닫는 순간
/// 진행 중인 영상 `jobId`가 사라진다. 서버 작업은 계속 돌고 있으므로 그걸 잃으면 결과를
/// 영원히 못 받는다.
///
/// `phase` 전환만 발행하고 기록 보관은 하지 않는다 — `records`는 `AppState`가 계속 소유한다
/// (ADR-0005의 관심사 분리와 같은 이유).
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
                phase = .finished(makeRecord(input: input, model: dto.model, score: dto.score, evidence: [], evidenceImageBase64: dto.evidenceImage))

            case .audio:
                phase = .running(.uploading)
                let dto = try await authStore.withValidAccessToken { [api] token in
                    try await api.analyzeAudio(file, accessToken: token)
                }
                phase = .finished(makeRecord(input: input, model: dto.model, score: dto.score, evidence: dto.evidence, evidenceImageBase64: nil))

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
                guard let detection = dto.aiDetection else {
                    // COMPLETED인데 결과가 없다 — 계약 위반이다. 성공으로 위장하지 않는다.
                    phase = .failed(.server)
                    return
                }
                phase = .finished(
                    makeRecord(
                        input: input,
                        model: detection.model,
                        score: detection.score,
                        evidence: detection.evidence,
                        evidenceImageBase64: detection.evidenceImage
                    )
                )
                return

            case .failed:
                pendingVideoJob = nil
                // 서버 `errorMessage`를 그대로 노출한다. "얼굴 없음"과 일반 오류를 문자열
                // 매칭으로 가르지 않는다(불일치 보고서 M4).
                phase = .failed(.jobFailed(dto.errorMessage ?? "영상 분석에 실패했습니다."))
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

    private func makeRecord(
        input: AnalysisInput,
        model: String,
        score: Double,
        evidence: [EvidenceDTO],
        evidenceImageBase64: String?
    ) -> AnalysisRecord {
        AnalysisRecord(
            date: .now,
            input: input,
            aiProbability: score,
            summary: Self.summary(for: score),
            aiEvidence: evidence.map(EvidenceItem.init(dto:)),
            model: model,
            evidenceImage: evidenceImageBase64.flatMap { Data(base64Encoded: $0) },
            riskLevel: Self.demoRiskLevel(for: score),
            riskEvidence: []
        )
    }

    /// 서버는 요약 문구를 주지 않는다. `score` 구간에서 확실히 말할 수 있는 것만 쓰고,
    /// 출처·유포 이력처럼 **서버가 판단하지 않은 것은 쓰지 않는다.**
    private static func summary(for score: Double) -> String {
        switch score {
        case ..<0.35:
            "AI로 생성된 흔적이 뚜렷하지 않습니다. 다만 이 결과만으로 진위를 단정할 수는 없습니다."
        case ..<0.7:
            "판단이 어려운 구간입니다. AI 생성 가능성을 배제할 수 없으니 출처를 함께 확인해 주세요."
        default:
            "AI로 생성되었을 가능성이 높습니다. 공유하거나 신뢰하기 전에 출처를 확인해 주세요."
        }
    }

    /// 목 모드에서만 데모용 사기 위험도를 만든다.
    ///
    /// **Release에서는 `#if DEBUG`로 함수 본문이 사라져 항상 `nil`이다** — 서버에 사기 판정이
    /// 없는 동안 근거 없는 위험도가 실사용자에게 노출되는 것을 컴파일 단계에서 막는다.
    private static func demoRiskLevel(for score: Double) -> RiskLevel? {
        #if DEBUG
        guard AppConfig.isMockAnalysisAPIEnabled else { return nil }
        return score > 0.7 ? .high : (score > 0.4 ? .medium : .low)
        #else
        return nil
        #endif
    }

    private static func mapped(_ error: Error) -> AnalysisError {
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

extension EvidenceItem {
    /// 서버 `Evidence` → UI 근거 항목.
    ///
    /// `severity`는 항상 `nil`이다 — 서버가 심각도를 주지 않으므로 전체 점수에서 역산해
    /// 붙이지 않는다(그건 서버가 말하지 않은 것을 지어내는 것이다).
    init(dto: EvidenceDTO) {
        self.init(
            icon: Self.icon(for: dto.tags),
            title: dto.title,
            detail: Self.detailWithTimeRange(dto),
            severity: nil
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
