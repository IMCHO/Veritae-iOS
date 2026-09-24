import Foundation

#if DEBUG

/// 목/실 구현을 **호출마다** 골라 위임하는 DEBUG 전용 래퍼.
///
/// `AuthStore`/`AnalysisStore` 는 앱 시작 시 한 번만 만들어지고 그때 받은 `api` 를 계속 쓴다.
/// 그래서 `AppConfig.makeAuthAPI()` 가 한쪽 구현을 골라 반환하면 **재실행 없이는 모드를 바꿀 수
/// 없다.** 서버가 미배포인 동안 목/실서버를 자주 왕복해야 하는데, 그때마다 Xcode 스킴의 런치
/// 인자를 고치고 다시 실행하는 것은 현실적이지 않다.
///
/// 래퍼가 매 호출에서 `AppConfig.isMockAuthAPIEnabled` 를 읽으므로 화면의 토글이 즉시 반영된다.
/// **Release 에서는 파일 전체가 컴파일되지 않고 `AppConfig` 가 실 구현을 직접 반환한다.**
struct SwitchableAuthAPI: AuthAPI {
    let live: AuthAPI
    let mock: AuthAPI

    private nonisolated var current: AuthAPI {
        AppConfig.isMockAuthAPIEnabled ? mock : live
    }

    nonisolated func signUp(email: String, password: String, nickname: String) async throws -> MemberDTO {
        try await current.signUp(email: email, password: password, nickname: nickname)
    }

    nonisolated func logIn(email: String, password: String) async throws -> TokenPairDTO {
        try await current.logIn(email: email, password: password)
    }

    nonisolated func refresh(refreshToken: String) async throws -> AccessTokenDTO {
        try await current.refresh(refreshToken: refreshToken)
    }

    nonisolated func me(accessToken: String) async throws -> MemberDTO {
        try await current.me(accessToken: accessToken)
    }
}

struct SwitchableAnalysisAPI: AnalysisAPI {
    let live: AnalysisAPI
    let mock: AnalysisAPI

    private nonisolated var current: AnalysisAPI {
        AppConfig.isMockAnalysisAPIEnabled ? mock : live
    }

    nonisolated func analyzeImage(_ file: UploadFile, accessToken: String) async throws -> ImageAnalysisResponseDTO {
        try await current.analyzeImage(file, accessToken: accessToken)
    }

    nonisolated func analyzeAudio(_ file: UploadFile, accessToken: String) async throws -> AudioAnalysisResponseDTO {
        try await current.analyzeAudio(file, accessToken: accessToken)
    }

    nonisolated func submitVideo(_ file: UploadFile, accessToken: String) async throws -> String {
        try await current.submitVideo(file, accessToken: accessToken)
    }

    /// **목 인스턴스를 매번 새로 만들지 않는 것이 중요하다.** `MockAnalysisAPI` 는 영상 job
    /// 상태를 자기 안(actor)에 들고 있어서, 새로 만들면 접수한 job 을 조회할 수 없다.
    /// `mock` 을 `let` 으로 붙잡아 두는 이유다.
    nonisolated func job(id: String, accessToken: String) async throws -> AnalysisJobDTO {
        try await current.job(id: id, accessToken: accessToken)
    }

    nonisolated func records(accessToken: String) async throws -> [AnalysisRecordDTO] {
        try await current.records(accessToken: accessToken)
    }

    nonisolated func report(accessToken: String) async throws -> AnalysisReportDTO {
        try await current.report(accessToken: accessToken)
    }
}

#endif
