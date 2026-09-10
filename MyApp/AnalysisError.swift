import Foundation

/// UI 레이어가 보는 분석 오류. `AuthAPIError`(전송 계층)를 analysis errorCode 기반으로
/// 재정의한다. `AuthError`와 같은 구조다 — raw network error가 View까지 흘러가지 않는다.
enum AnalysisError: LocalizedError, Sendable {
    /// 400 `INVALID_IMAGE_FILE` / `INVALID_AUDIO_FILE` / `INVALID_VIDEO_FILE`.
    /// 서버 `detail`에 형식·용량 사유가 담겨 있어 **그대로 노출한다** — 재작성하면
    /// "지원하지 않는 파일 형식입니다: image/heic" 같은 구체적 원인이 사라진다.
    case invalidFile(String)
    /// 502 `DETECTION_SERVICE_UNAVAILABLE` — 탐지 서버(별도 인프라) 호출 실패. 재시도 대상이다.
    case detectionServiceUnavailable
    /// 404 `ANALYSIS_JOB_NOT_FOUND` — 내 작업이 아니거나 사라짐. 진행 상태를 폐기해야 한다.
    case jobNotFound
    /// 401 계열 — 재시도 후에도 UNAUTHORIZED면 세션 종료.
    case sessionExpired
    /// 업로드 전 클라 선검증에서 걸러낸 경우. 서버 왕복 없이 즉시 안내한다.
    case unsupportedInput(String)
    /// 오프라인·타임아웃.
    case network
    /// 500 또는 2xx 스키마 불일치.
    case server
    /// 영상 job이 FAILED로 끝난 경우 — 서버 `errorMessage`를 그대로 노출한다.
    ///
    /// "얼굴 없음"과 일반 서버 오류를 **문자열 매칭으로 가르지 않는다.** 서버가 둘을 구분해
    /// 두었지만 기계 판독 필드가 없어(불일치 보고서 M4) 문구 매칭이 유일한 수단인데, 그건
    /// 서버가 문구를 다듬는 순간 조용히 깨진다. M4가 해소되면 그때 분기한다.
    case jobFailed(String)
    /// 그 외 — 미지 errorCode / 상태코드 폴백.
    case unknown(String)

    /// `AuthAPIError` → `AnalysisError` 매핑.
    ///
    /// errorCode는 `String`으로만 비교한다. 서버가 스펙에 없는 코드를 실제로 발행하므로
    /// (`INVALID_*_FILE` 3종 + 프레임워크 레벨의 `HttpStatus` 이름 백필 — 불일치 보고서 M2·M3)
    /// 닫힌 `enum` 디코딩은 오류 본문 전체를 잃게 만든다.
    init(apiError: AuthAPIError) {
        switch apiError {
        case .problem(let problem, let status):
            if let code = problem.errorCode, let known = AnalysisErrorCode(rawValue: code) {
                switch known {
                case .invalidImageFile, .invalidAudioFile, .invalidVideoFile:
                    self = .invalidFile(problem.detail ?? "이 파일은 분석할 수 없습니다.")
                case .detectionServiceUnavailable:
                    self = .detectionServiceUnavailable
                case .analysisJobNotFound:
                    self = .jobNotFound
                }
            } else if let code = problem.errorCode, code == KnownErrorCode.unauthorized.rawValue {
                self = .sessionExpired
            } else if let detail = problem.detail, !detail.isEmpty {
                // errorCode가 부재·미지여도 서버가 사람이 읽을 수 있는 `detail`을 줬다면
                // 고정 문구보다 그걸 우선한다 — 느슨한 디코딩의 실제 이득(ADR-0011).
                self = .unknown(detail)
            } else {
                self = Self.statusFallback(status)
            }
        case .http(let status):
            self = Self.statusFallback(status)
        case .transport:
            self = .network
        case .decoding:
            self = .server
        }
    }

    private static func statusFallback(_ status: Int) -> AnalysisError {
        if status == 401 {
            return .sessionExpired
        }
        if status == 404 {
            return .jobNotFound
        }
        if status == 413 {
            // 프레임워크 레벨 업로드 용량 초과. errorCode는 `PAYLOAD_TOO_LARGE`로 추정되며
            // 스펙에 없다(불일치 보고서 M3/Q2) — 상태코드로 잡아 구체적으로 안내한다.
            return .invalidFile("파일이 너무 큽니다. 더 작은 파일로 다시 시도해 주세요.")
        }
        if (500...599).contains(status) {
            return .server
        }
        return .unknown("분석 요청을 처리할 수 없습니다. 잠시 후 다시 시도해 주세요.")
    }

    var errorDescription: String? {
        switch self {
        case .invalidFile(let message): message
        case .detectionServiceUnavailable: "분석 서버에 연결할 수 없습니다. 잠시 후 다시 시도해 주세요."
        case .jobNotFound: "분석 작업을 찾을 수 없습니다. 다시 시도해 주세요."
        case .sessionExpired: "세션이 만료되었습니다. 다시 로그인해 주세요."
        case .unsupportedInput(let message): message
        case .network: "네트워크에 연결할 수 없습니다. 잠시 후 다시 시도해 주세요."
        case .server: "일시적인 오류가 발생했습니다. 잠시 후 다시 시도해 주세요."
        case .jobFailed(let message): message
        case .unknown(let message): message
        }
    }

    /// 사용자에게 재시도 버튼을 보여줄지 판단한다. 파일 자체가 문제인 경우
    /// (`invalidFile`/`unsupportedInput`)는 같은 파일로 재시도해도 결과가 같으므로 숨긴다.
    var isRetryable: Bool {
        switch self {
        case .detectionServiceUnavailable, .network, .server, .jobNotFound, .unknown:
            true
        case .invalidFile, .unsupportedInput, .sessionExpired, .jobFailed:
            false
        }
    }
}

// MARK: - 업로드 전 클라 선검증

/// 서버 `validate()`와 같은 규칙을 클라에서 먼저 적용해 왕복을 줄인다.
///
/// 서버 값을 그대로 옮긴 것이다 — `ImageAnalysisService` / `AudioAnalysisService` /
/// `VideoAnalysisService`의 `ALLOWED_CONTENT_TYPES` · `MAX_FILE_SIZE_BYTES`.
/// **서버가 상한을 늘리면 여기가 유효한 파일을 막는 회귀가 된다**(ADR-0004가 비밀번호에서
/// 겪은 것과 같은 함정) — 그래서 형식은 정확히 대조하고 용량은 서버와 동일 값만 쓴다.
enum UploadRule {
    static let imageContentTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]
    static let audioContentTypes: Set<String> = [
        "audio/wav", "audio/x-wav", "audio/mpeg", "audio/mp4", "audio/aac",
    ]
    static let videoContentTypes: Set<String> = ["video/mp4", "video/quicktime", "video/x-msvideo"]

    static let audioMaxBytes = 25 * 1024 * 1024
    static let videoMaxBytes = 100 * 1024 * 1024

    /// 업로드를 막아야 하면 사용자용 문구를 반환한다. `nil`이면 통과.
    static func submitBlockingHint(for file: UploadFile) -> String? {
        if file.data.isEmpty {
            return "빈 파일은 분석할 수 없습니다."
        }
        switch file.kind {
        case .image:
            guard imageContentTypes.contains(file.contentType) else {
                return "이미지는 JPEG · PNG · WebP만 분석할 수 있습니다."
            }
        case .audio:
            guard audioContentTypes.contains(file.contentType) else {
                return "음성은 WAV · MP3 · M4A · AAC만 분석할 수 있습니다."
            }
            guard file.data.count <= audioMaxBytes else {
                return "음성 파일은 25MB까지 분석할 수 있습니다."
            }
        case .video:
            guard videoContentTypes.contains(file.contentType) else {
                return "영상은 MP4 · MOV · AVI만 분석할 수 있습니다."
            }
            guard file.data.count <= videoMaxBytes else {
                return "영상 파일은 100MB까지 분석할 수 있습니다. 더 짧은 영상으로 시도해 주세요."
            }
        }
        return nil
    }
}
