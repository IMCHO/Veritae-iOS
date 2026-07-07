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
    var severity: RiskLevel
}

/// 하나의 분석 기록
struct AnalysisRecord: Identifiable {
    let id = UUID()
    var date: Date
    var input: AnalysisInput
    var aiProbability: Double        // 0.0 ~ 1.0
    var riskLevel: RiskLevel
    var summary: String
    var aiEvidence: [EvidenceItem]   // AI 판독 근거
    var riskEvidence: [EvidenceItem] // 위험도 분석

    var aiLevel: RiskLevel {
        switch aiProbability {
        case ..<0.35: .low
        case ..<0.7: .medium
        default: .high
        }
    }
}

// MARK: - 분석 엔진 (Mock)

/// 서버 연동 전까지 사용하는 가짜 분석 엔진
enum AnalysisEngine {
    static func analyze(_ input: AnalysisInput) async -> AnalysisRecord {
        // 실제 서버 분석을 흉내 내는 지연
        try? await Task.sleep(for: .seconds(3.2))

        let probability = Double.random(in: 0.15...0.95)
        let risk: RiskLevel = probability > 0.7 ? .high : (probability > 0.4 ? .medium : .low)

        return AnalysisRecord(
            date: .now,
            input: input,
            aiProbability: probability,
            riskLevel: risk,
            summary: probability > 0.5
                ? "이 콘텐츠는 AI로 생성되었을 가능성이 높습니다. 공유하거나 신뢰하기 전에 출처를 확인하세요."
                : "AI 생성 흔적이 뚜렷하지 않습니다. 다만 일부 구간에서 편집 흔적이 발견되었습니다.",
            aiEvidence: [
                EvidenceItem(
                    icon: "waveform.path.ecg",
                    title: "주파수 패턴 분석",
                    detail: "고주파 영역에서 생성 모델 특유의 규칙적인 노이즈 패턴이 감지되었습니다. 자연 촬영물에서는 나타나기 어려운 분포입니다.",
                    severity: probability > 0.5 ? .high : .low
                ),
                EvidenceItem(
                    icon: "eye",
                    title: "시각적 일관성 검사",
                    detail: "조명 방향과 그림자의 물리적 일관성을 검사했습니다. 광원 대비 그림자 각도의 오차가 허용 범위 내에 있습니다.",
                    severity: .low
                ),
                EvidenceItem(
                    icon: "square.grid.3x3",
                    title: "픽셀 경계 분석",
                    detail: "객체 경계부에서 업스케일링 아티팩트가 부분적으로 관찰됩니다. 생성 후 후처리가 있었을 가능성이 있습니다.",
                    severity: .medium
                ),
                EvidenceItem(
                    icon: "doc.badge.gearshape",
                    title: "메타데이터 검증",
                    detail: "촬영 기기 정보(EXIF)가 제거되어 있습니다. 원본 출처를 확인할 수 없어 신뢰도 평가에 반영되었습니다.",
                    severity: .medium
                ),
            ],
            riskEvidence: [
                EvidenceItem(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "사칭 가능성",
                    detail: "알려진 인물 데이터베이스와 대조한 결과 유사도가 낮아 특정 인물 사칭 정황은 발견되지 않았습니다.",
                    severity: .low
                ),
                EvidenceItem(
                    icon: "exclamationmark.bubble",
                    title: "유포 이력",
                    detail: risk == .high
                        ? "동일하거나 유사한 콘텐츠가 사기 신고 커뮤니티에서 2건 보고된 이력이 있습니다."
                        : "유사 콘텐츠의 사기 신고 이력이 확인되지 않았습니다.",
                    severity: risk
                ),
                EvidenceItem(
                    icon: "shield.lefthalf.filled",
                    title: "종합 위험 평가",
                    detail: "AI 생성 가능성, 유포 이력, 콘텐츠 맥락을 종합해 위험도를 산정했습니다. 금전 요구나 개인정보 요청과 함께 수신했다면 주의하세요.",
                    severity: risk
                ),
            ]
        )
    }
}

// MARK: - 앱 상태

/// 화면 전환 단계
enum AppPhase {
    case splash
    case login
    case main
}

@Observable
final class AppState {
    var phase: AppPhase = .splash
    var userEmail: String?
    var records: [AnalysisRecord] = []

    /// 스플래시 종료 후 다음 화면 결정
    func finishSplash() {
        phase = userEmail == nil ? .login : .main
    }

    /// 로그인 (Mock: 서버 검증 흉내)
    func signIn(email: String, password: String) async throws {
        try await Task.sleep(for: .seconds(1))
        guard email.contains("@"), password.count >= 8 else {
            throw AuthError.invalidCredentials
        }
        userEmail = email
        phase = .main
    }

    /// 회원가입 (Mock: 유일성/안전성 서버 확인 흉내)
    func signUp(email: String, password: String) async throws {
        try await Task.sleep(for: .seconds(1.2))
        guard email.contains("@"), email.contains(".") else {
            throw AuthError.invalidEmail
        }
        guard password.count >= 8 else {
            throw AuthError.weakPassword
        }
        // 이미 사용 중인 이메일 흉내
        if email.lowercased().hasPrefix("taken") {
            throw AuthError.emailTaken
        }
    }

    func signOut() {
        userEmail = nil
        records.removeAll()
        phase = .login
    }
}

enum AuthError: LocalizedError {
    case invalidCredentials
    case invalidEmail
    case weakPassword
    case emailTaken

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "이메일 또는 비밀번호를 확인해 주세요."
        case .invalidEmail: "올바른 이메일 형식이 아닙니다."
        case .weakPassword: "비밀번호는 8자 이상이어야 합니다."
        case .emailTaken: "이미 사용 중인 이메일입니다."
        }
    }
}
