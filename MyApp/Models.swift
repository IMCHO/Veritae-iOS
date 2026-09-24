import SwiftUI
import Observation

// MARK: - 입력 소스

/// 분석 가능한 입력 소스의 종류
enum SourceKind: String, CaseIterable, Identifiable {
    case photo
    case video
    case link
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: "사진"
        case .video: "영상"
        case .link: "링크"
        case .file: "파일"
        }
    }

    var icon: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .link: "link"
        case .file: "doc"
        }
    }
}

/// 사용자가 선택한 분석 대상
struct AnalysisInput: Equatable {
    var kind: SourceKind
    var title: String
    var subtitle: String
    var previewImage: UIImage?
    /// 서버로 올릴 실제 바이트. 링크 입력은 대응 엔드포인트가 없어 항상 `nil` 이다.
    ///
    /// 사진은 **JPEG로 재인코딩된 결과**가 들어온다 — iPhone 기본 촬영 포맷(HEIC)을 그대로
    /// 올리면 서버 `ImageAnalysisService`가 400 `INVALID_IMAGE_FILE`을 낸다(허용 형식은
    /// jpeg/png/webp뿐). 변환 지점은 `MainView.loadPickedMedia`다.
    var file: UploadFile?
    /// 음성 파일의 RMS 파형(0~1). 선택 시점에 한 번 계산해 메인 미리보기와 결과 화면이 공유한다 —
    /// 파일명만 보여주면 "무엇을 골랐는지"가 안 보인다.
    var waveform: [Float]? = nil

    static func == (lhs: AnalysisInput, rhs: AnalysisInput) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
    }
}

// MARK: - 분석 결과

/// 위험도 단계
enum RiskLevel: String, CaseIterable {
    case low
    case medium
    case high

    /// 점수(0~1) → 단계. **AI 생성 가능성과 사기 위험도가 같은 구간을 쓴다** — 한 화면에 두 판정이
    /// 나란히 놓이므로 "높음"의 의미가 서로 달라서는 안 된다. 사기 탐지용 임계값을 따로 발명하지 않는다.
    ///
    /// 서버 통계(`/analysis/report`)는 0.5 고정 임계값으로 "탐지됨"을 센다 — 이 3구간과는 별개다.
    static let lowUpperBound = 0.35
    static let mediumUpperBound = 0.7

    init(score: Double) {
        switch score {
        case ..<Self.lowUpperBound: self = .low
        case ..<Self.mediumUpperBound: self = .medium
        default: self = .high
        }
    }

    var label: String {
        switch self {
        case .low: "낮음"
        case .medium: "보통"
        case .high: "높음"
        }
    }

    var color: Color {
        switch self {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}

/// 판독 근거 항목
struct EvidenceItem: Identifiable {
    let id = UUID()
    var icon: String
    var title: String
    var detail: String
    /// **옵셔널이다.** AI 판독 `Evidence` 스키마에는 심각도가 없다 — 전체 `score`로 개별 근거의
    /// 심각도를 계산해 붙이면 서버가 말하지 않은 것을 지어내는 것이 된다. `nil`이면 UI가
    /// 뱃지를 감춘다. 사기 탐지 근거 문장은 서버가 문장별 `score` 를 주므로 그 값으로 채운다.
    var severity: RiskLevel?
    /// 서버 `startSec`~`endSec`. 음성·영상의 근거는 **시간 구간**이라 텍스트 카드가 아니라
    /// 타임라인 마커로 그린다 — 눌러서 그 지점으로 이동할 수 있어야 근거로서 의미가 있다.
    var timeRange: ClosedRange<Double>? = nil
}

/// 하나의 분석 기록. 방금 끝난 분석(원본 미디어 있음)과 서버 기록(원본 미디어 없음)을 같은 타입으로
/// 표현하고, 결과 화면도 하나다(ADR-0017). "AI 판독 없음" 은 `aiProbability == nil` 이다(ADR-0018).
struct AnalysisRecord: Identifiable {
    /// 서버 기록은 서버 `id`, 방금 끝난 분석은 로컬 UUID. `String` — 서버 id 포맷을 가정하지 않는다(ADR-0012).
    /// 목록을 다시 불러와도 같은 기록은 같은 id 여야 네비게이션 대상이 유지된다.
    var id: String = UUID().uuidString
    /// **표시일 뿐이다.** 서버 `createdAt` 파싱에 실패하면 `nil` — 크래시하거나 "지금"으로 위장하지
    /// 않는다. 목록 순서는 서버가 준 순서(최신순)를 그대로 쓰므로 이 값에 의존하지 않는다.
    var date: Date?
    /// 무엇을 분석했나. 원본 미디어가 없는 서버 기록도 결과 화면 구성(히어로·타임라인·범례)을 이것으로 고른다.
    var modality: UploadFile.Kind
    /// 원본 미디어. **서버 기록은 항상 `nil`이다** — 서버가 썸네일·원본을 주지 않는다(ADR-0017).
    /// `nil` 이면 결과 화면은 미리보기·재생·파형 없이 판독 결과만으로 그려진다.
    var input: AnalysisInput?
    /// 0.0 ~ 1.0. **`nil` 이면 AI 판독이 없다** — 얼굴을 못 찾은 영상(`NO_FACE_DETECTED`) 등.
    /// 0 으로 채우면 "AI 아님"으로 읽혀 거짓 판정이 된다(ADR-0018).
    var aiProbability: Double?
    var summary: String?
    var aiEvidence: [EvidenceItem]   // AI 판독 근거
    /// 탐지에 사용된 모델 이름 (`spai` / `antideepfake` / `dfdc`). AI 판독이 없으면 `nil`.
    var model: String?
    /// 판독 근거 히트맵(base64 PNG를 디코딩한 것). 이미지·영상에서 서버가 best-effort로 준다 —
    /// 언제든 `nil`일 수 있고, 음성은 항상 `nil`이다.
    var evidenceImage: Data?

    /// 사기 위험도. 서버 `scamDetection.score` 를 `RiskLevel(score:)` 로 옮긴 값이다.
    /// `nil` 이면 서버가 `scamDetection` 키를 뺀 경우다 — image/audio 는 "텍스트 없음"이 확정이지만
    /// 영상은 명세가 그 의미를 적지 않았다. 그래서 UI 는 `nil` 이면 카드·뱃지를 **감추기만** 하고
    /// 이유를 말하지 않는다.
    var riskLevel: RiskLevel?
    /// 사기 탐지 근거 문장(서버 `scamDetection.evidence`).
    var riskEvidence: [EvidenceItem]
    /// 서버가 준 부분 결과 사유(예: 얼굴 없음). 사용자에게 **그대로** 보여주기만 하고 분기에 쓰지 않는다.
    var notice: String? = nil

    /// 결과 화면에 보일 안내. AI 판독이 빠졌는데 사유 문구가 하나도 없으면(서버가 `errorCode`·
    /// `errorMessage` 없이 AI 판독만 비운 COMPLETED 등) **이유를 단정하지 않는** 기본 문구로 채운다 —
    /// 게이지도 설명도 없이 사기 카드만 남으면 AI 판독이 왜 빠졌는지 알 수 없다. 서버 문구가 있으면 그게 우선.
    var displayedNotice: String? {
        notice ?? (aiProbability == nil ? Self.missingAINotice(errorCode: nil) : nil)
    }

    var aiLevel: RiskLevel? {
        aiProbability.map { RiskLevel(score: $0) }
    }
}

// MARK: - 앱 상태

/// 화면 전환 단계
enum AppPhase {
    case splash
    case login
    case main
}

/// `phase`(화면 단계)를 소유하고, 인증은 `AuthStore`에 위임한다(ADR-0005).
/// 분석 기록의 정본은 서버다 — `history` 가 `GET /analysis/records` 로 불러온다(ADR-0017).
/// `AuthStore`를 별도로 환경 주입하지 않고 이 타입이 조합해 주입 지점을 하나로 유지한다
/// (`ContentView.swift`가 유일한 실주입 지점, 프리뷰 5곳은 기본 인자로 동작).
@Observable
final class AppState {
    var phase: AppPhase = .splash
    let authStore: AuthStore
    /// 분석 실행 스토어. **`AppState`가 소유해야 한다** — 모달이 소유하면 사용자가 화면을
    /// 닫는 순간 진행 중인 영상 `jobId`가 사라지고, 서버는 계속 분석하는데 결과를 받을 길이 없어진다.
    let analysisStore: AnalysisStore
    /// 계정 화면의 분석 기록. **로컬에 쌓지 않는다** — 재실행해도 남고 기기 간에도 같은 목록이어야 해서
    /// 서버 기록(`GET /analysis/records`)을 화면 진입 때마다 불러온다(ADR-0017).
    let history: AnalysisHistoryStore

    @MainActor
    init(authStore: AuthStore, analysisAPI: AnalysisAPI) {
        self.authStore = authStore
        self.analysisStore = AnalysisStore(api: analysisAPI, authStore: authStore)
        self.history = AnalysisHistoryStore(api: analysisAPI, authStore: authStore)
    }

    /// 기본 인자로 `AuthStore(api: AppConfig.makeAuthAPI())`를 만들고 싶지만, default parameter
    /// value 표현식은 (모듈 전체가 MainActor 기본 격리라도) 항상 nonisolated 컨텍스트로 컴파일된다.
    /// `AuthStore.init`은 `@MainActor`라 그 위치에서 직접 호출할 수 없어, `@MainActor` 본문을
    /// 가진 convenience init으로 옮긴다 — 6개 호출부(`AppState()`, `ContentView.swift`/프리뷰 5곳)는
    /// 그대로 `AppState()`만 쓰면 된다(ADR-0005).
    @MainActor
    convenience init() {
        self.init(
            authStore: AuthStore(api: AppConfig.makeAuthAPI()),
            analysisAPI: AppConfig.makeAnalysisAPI()
        )
    }

    /// 클라이언트 전용 로그아웃(ADR-0002) — 서버 호출 없음. 계정 화면 버튼 동작은 유지.
    func signOut() {
        Task {
            await authStore.signOut()
            history.clear()
            phase = .login
        }
    }
}
