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

    /// `-UseMockAuthAPI 1` 런치 인자로 전환되는 목 모드 (ADR-0001, PRD iOS-4).
    /// Xcode의 `-Key Value` 형식 런치 인자는 `NSArgumentDomain`에 자동 등록되므로
    /// `UserDefaults`로 읽는 것이 표준 방식이다 — 직접 `ProcessInfo.arguments`를 파싱하지 않는다.
    ///
    /// **DEBUG 전용이다.** `UserDefaults` 로 켜지는 스위치가 Release 에 남으면 목 구현이
    /// 자격 증명 검증 없이 토큰을 발급하는 인증 우회 경로가 된다.
    static var isMockAuthAPIEnabled: Bool {
        UserDefaults.standard.bool(forKey: "UseMockAuthAPI")
    }

    /// `-MockAuthScenario <case>` 런치 인자 — 목 모드에서 오류 케이스 재현용 (PRD E15).
    static var mockAuthScenario: MockAuthAPI.Scenario? {
        guard let raw = UserDefaults.standard.string(forKey: "MockAuthScenario") else { return nil }
        return MockAuthAPI.Scenario(rawValue: raw)
    }

#endif

    /// 목/실 `AuthAPI` 전환 지점 (ADR-0001).
    /// Release 에서는 분기 자체가 컴파일되지 않으므로 항상 `LiveAuthAPI` 다.
    static func makeAuthAPI() -> AuthAPI {
        #if DEBUG
        if isMockAuthAPIEnabled {
            return MockAuthAPI(scenario: mockAuthScenario)
        }
        #endif
        return LiveAuthAPI(baseURL: baseURL)
    }
}
