import Foundation

/// 빌드 구성으로 외부화된 값 (ADR-0001, PRD iOS-1).
///
/// xcconfig는 스킴/호스트를 분리 정의하고(`Config/Debug.xcconfig`, `Config/Release.xcconfig`),
/// 부분 Info.plist(`Config/{Debug,Release}-Info.plist`)가 `INFOPLIST_FILE`로 병합되면서
/// `$(VERITAE_API_SCHEME)`/`$(VERITAE_API_HOST)` 치환을 통해 실려 온다.
/// (`INFOPLIST_KEY_<커스텀키>`는 Apple이 아는 표준 키만 반영되므로 쓸 수 없다 — 실측 확인됨.)
/// 여기서는 그 값을 읽어 `baseURL`을 조립하기만 한다 — 값 자체를 하드코딩하지 않는다.
enum AppConfig {
    /// 구성별 API base URL. 예: Debug → `http://localhost:8080`, Release → `https://api.veritae.app`.
    static var baseURL: URL {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "VeritaeAPIScheme") as? String ?? "https"
        let host = Bundle.main.object(forInfoDictionaryKey: "VeritaeAPIHost") as? String ?? "api.veritae.app"
        guard let url = URL(string: "\(scheme)://\(host)") else {
            preconditionFailure("잘못된 VERITAE_API_SCHEME/VERITAE_API_HOST 빌드 설정: \(scheme)://\(host)")
        }
        return url
    }

#if DEBUG

    // TEMP-UNTIL-SERVER(mock-mode-flag): 목 모드 플래그 3종 + mockModeKey. 실서버 배포 후 삭제한다.
    // 삭제하면 `Switchable*API` 도 함께 삭제되고 `make*API()` 는 Live 만 반환하면 된다.
    /// 앱 안에서 켜고 끄는 목 모드. 런치 인자를 다시 주려면 Xcode 스킴을 고치고 재실행해야
    /// 하는데, 서버가 미배포인 동안은 목/실서버를 자주 왕복하게 되므로 화면에서 바꿀 수단이 필요하다.
    /// `DebugModeSwitcher` 가 이 값을 토글하고, `Switchable*API` 가 호출마다 이 값을 읽는다.
    private nonisolated static let mockModeKey = "VeritaeDebugMockMode"

    // LL-002: 아래 세 플래그는 `nonisolated` 여야 한다. `Switchable*API` 가 `nonisolated`
    // 메서드에서 매 호출 읽는데, 무표기면 모듈 기본 격리(MainActor) 때문에 Swift 6 에서
    // "can not be referenced from a nonisolated context" 오류가 된다(실측).
    // `UserDefaults` 자체는 스레드 안전하다.

    nonisolated static var isMockModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: mockModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: mockModeKey) }
    }

    /// 런치 인자로 목이 켜져 있는가.
    ///
    /// 런치 인자는 `NSArgumentDomain` 에 등록돼 **항상 이긴다** — 이 경우 화면 토글로 끌 수 없다.
    /// 그 사실을 오버레이가 표시하지 않으면 "목 모드인데 실서버 모드라고 나오고, 토글도 안 듣는다"
    /// 는 혼란이 생긴다(실제로 겪었다). `DebugModeSwitcher` 가 이 값으로 토글을 비활성화한다.
    nonisolated static var isMockModeForcedByLaunchArgument: Bool {
        UserDefaults.standard.bool(forKey: "UseMockAuthAPI")
            || UserDefaults.standard.bool(forKey: "UseMockAnalysisAPI")
    }

    /// `-UseMockAuthAPI 1` 런치 인자 또는 화면에서 켠 목 모드 (ADR-0001, PRD iOS-4).
    /// Xcode의 `-Key Value` 형식 런치 인자는 `NSArgumentDomain`에 자동 등록되므로
    /// `UserDefaults`로 읽는 것이 표준 방식이다 — 직접 `ProcessInfo.arguments`를 파싱하지 않는다.
    /// 런치 인자가 있으면 `NSArgumentDomain` 우선순위 때문에 그쪽이 항상 이긴다.
    ///
    /// **DEBUG 전용이다.** `UserDefaults` 로 켜지는 스위치가 Release 에 남으면 목 구현이
    /// 자격 증명 검증 없이 토큰을 발급하는 인증 우회 경로가 된다.
    nonisolated static var isMockAuthAPIEnabled: Bool {
        UserDefaults.standard.bool(forKey: "UseMockAuthAPI") || isMockModeEnabled
    }

    /// `-MockAuthScenario <case>` 런치 인자 — 목 모드에서 오류 케이스 재현용 (PRD E15).
    static var mockAuthScenario: MockAuthAPI.Scenario? {
        guard let raw = UserDefaults.standard.string(forKey: "MockAuthScenario") else { return nil }
        return MockAuthAPI.Scenario(rawValue: raw)
    }

    /// `-UseMockAnalysisAPI 1` 런치 인자 또는 화면에서 켠 목 모드.
    ///
    /// 탐지 서버가 미배포라 기본 개발 경로다. `AnalysisStore.demoRiskLevel`도 이 값을 보고
    /// 데모용 사기 위험도를 채운다 — Release에서는 이 프로퍼티 자체가 존재하지 않아
    /// 근거 없는 위험도가 실사용자에게 노출될 수 없다.
    nonisolated static var isMockAnalysisAPIEnabled: Bool {
        UserDefaults.standard.bool(forKey: "UseMockAnalysisAPI") || isMockModeEnabled
    }

    /// `-MockAnalysisScenario <case>` 런치 인자 — 오류 케이스 재현용.
    static var mockAnalysisScenario: MockAnalysisAPI.Scenario? {
        guard let raw = UserDefaults.standard.string(forKey: "MockAnalysisScenario") else { return nil }
        return MockAnalysisAPI.Scenario(rawValue: raw)
    }

#endif

    // TEMP-UNTIL-SERVER(api-factory): 아래 두 팩토리의 `#if DEBUG` 분기. 삭제 후에는 각각
    // `LiveAuthAPI(baseURL:)` / `LiveAnalysisAPI(baseURL:)` 한 줄만 남긴다.
    /// 목/실 `AuthAPI` 전환 지점 (ADR-0001).
    ///
    /// DEBUG 에서는 **둘 다 들고 있는 래퍼**를 반환한다. 여기서 한쪽을 골라 반환하면 앱 시작
    /// 시점에 모드가 고정돼 재실행 없이는 바꿀 수 없다(`SwitchableAuthAPI` 주석 참고).
    /// Release 에서는 분기 자체가 컴파일되지 않으므로 항상 `LiveAuthAPI` 다.
    static func makeAuthAPI() -> AuthAPI {
        #if DEBUG
        return SwitchableAuthAPI(
            live: LiveAuthAPI(baseURL: baseURL),
            mock: MockAuthAPI(scenario: mockAuthScenario)
        )
        #else
        return LiveAuthAPI(baseURL: baseURL)
        #endif
    }

    /// 목/실 `AnalysisAPI` 전환 지점. `makeAuthAPI()`와 같은 구조다.
    static func makeAnalysisAPI() -> AnalysisAPI {
        #if DEBUG
        return SwitchableAnalysisAPI(
            live: LiveAnalysisAPI(baseURL: baseURL),
            mock: MockAnalysisAPI(scenario: mockAnalysisScenario)
        )
        #else
        return LiveAnalysisAPI(baseURL: baseURL)
        #endif
    }
}
