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
    /// **옵셔널이다.** 서버 `Evidence` 스키마에는 심각도가 없다 — 전체 `score`로 개별 근거의
    /// 심각도를 계산해 붙이면 서버가 말하지 않은 것을 지어내는 것이 된다. `nil`이면 UI가
    /// 뱃지를 감춘다.
    var severity: RiskLevel?
    /// 서버 `startSec`~`endSec`. 음성·영상의 근거는 **시간 구간**이라 텍스트 카드가 아니라
    /// 타임라인 마커로 그린다 — 눌러서 그 지점으로 이동할 수 있어야 근거로서 의미가 있다.
    var timeRange: ClosedRange<Double>? = nil
}

/// 하나의 분석 기록
struct AnalysisRecord: Identifiable {
    let id = UUID()
    var date: Date
    var input: AnalysisInput
    var aiProbability: Double        // 0.0 ~ 1.0
    var summary: String
    var aiEvidence: [EvidenceItem]   // AI 판독 근거
    /// 탐지에 사용된 모델 이름 (`spai` / `antideepfake` / `dfdc`).
    var model: String
    /// 판독 근거 히트맵(영상 전용, base64 PNG를 디코딩한 것). 서버가 best-effort로 주므로
    /// 항상 `nil`일 수 있다 — 이미지/음성은 언제나 `nil`이다.
    var evidenceImage: Data?

    /// 사기 위험도. **실서버 경로에서는 항상 `nil`이다** — 서버에 사기 판정 엔드포인트가
    /// 아예 없다(`docs/research/2026-09-10-fraud-detection-engines.md`). 목 모드에서만
    /// 데모용으로 채워지고, `nil`이면 UI가 카드·뱃지를 감춘다.
    ///
    /// 타입을 지우지 않고 옵셔널로 남긴 이유: 사기 엔진이 붙으면 값만 채우면 되고, 그때까지
    /// 근거 없는 판정이 화면에 뜨는 일은 구조적으로 막힌다.
    var riskLevel: RiskLevel?
    /// 위험도 분석 근거. `riskLevel`과 같은 이유로 실서버 경로에서는 항상 빈 배열이다.
    var riskEvidence: [EvidenceItem]

    var aiLevel: RiskLevel {
        switch aiProbability {
        case ..<0.35: .low
        case ..<0.7: .medium
        default: .high
        }
    }
}

// MARK: - 앱 상태

/// 화면 전환 단계
enum AppPhase {
    case splash
    case login
    case main
}

/// `phase`(화면 단계)와 `records`(분석 기록)만 소유하고, 인증은 `AuthStore`에 위임한다(ADR-0005).
/// `AuthStore`를 별도로 환경 주입하지 않고 이 타입이 조합해 주입 지점을 하나로 유지한다
/// (`ContentView.swift`가 유일한 실주입 지점, 프리뷰 5곳은 기본 인자로 동작).
@Observable
final class AppState {
    var phase: AppPhase = .splash
    var records: [AnalysisRecord] = []
    let authStore: AuthStore
    /// 분석 실행 스토어. **`AppState`가 소유해야 한다** — 모달이 소유하면 사용자가 화면을
    /// 닫는 순간 진행 중인 영상 `jobId`가 사라지고, 서버는 계속 분석하는데 결과를 받을 길이 없어진다.
    let analysisStore: AnalysisStore

    @MainActor
    init(authStore: AuthStore, analysisAPI: AnalysisAPI) {
        self.authStore = authStore
        self.analysisStore = AnalysisStore(api: analysisAPI, authStore: authStore)
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
            records.removeAll()
            phase = .login
        }
    }
}
