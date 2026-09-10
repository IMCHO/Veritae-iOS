import Foundation
import Testing

@testable import MyApp

// MARK: - 스텁

/// 호출 횟수 기록. 스텁이 struct(Sendable)라 가변 상태를 actor로 분리한다.
private actor CallLog {
    var analyzeImageCalls = 0
    var submitVideoCalls = 0
    var jobCalls = 0
    var refreshCalls = 0
    /// analyze 가 받은 accessToken 순서 — 재시도가 **새 토큰으로** 갔는지 확인한다.
    var seenTokens: [String] = []

    func recordAnalyzeImage(token: String) -> Int {
        analyzeImageCalls += 1
        seenTokens.append(token)
        return analyzeImageCalls
    }

    func recordSubmitVideo() { submitVideoCalls += 1 }
    func recordJob() -> Int { jobCalls += 1; return jobCalls }
    func recordRefresh() { refreshCalls += 1 }
}

private struct StubAnalysisAPI: AnalysisAPI {
    let log: CallLog
    /// 첫 호출을 401 UNAUTHORIZED 로 실패시킨다.
    var failFirstWithUnauthorized = false
    /// `job(id:)` 이 돌려줄 상태·본문.
    var jobResponse: AnalysisJobDTO?

    nonisolated func analyzeImage(_ file: UploadFile, accessToken: String) async throws -> ImageDetectionDTO {
        let count = await log.recordAnalyzeImage(token: accessToken)
        if failFirstWithUnauthorized, count == 1 {
            throw Self.unauthorized()
        }
        return ImageDetectionDTO(model: "spai", score: 0.42, evidenceImage: nil)
    }

    nonisolated func analyzeAudio(_ file: UploadFile, accessToken: String) async throws -> AudioDetectionDTO {
        AudioDetectionDTO(model: "antideepfake", score: 0.1, evidence: [])
    }

    nonisolated func submitVideo(_ file: UploadFile, accessToken: String) async throws -> String {
        await log.recordSubmitVideo()
        return "job-1"
    }

    nonisolated func job(id: String, accessToken: String) async throws -> AnalysisJobDTO {
        _ = await log.recordJob()
        return jobResponse ?? AnalysisJobDTO(jobId: id, status: "COMPLETED", aiDetection: nil, errorMessage: nil)
    }

    nonisolated static func unauthorized() -> AuthAPIError {
        .problem(
            ProblemDetail(
                type: nil, title: nil, status: 401, detail: nil, instance: nil,
                errorCode: "UNAUTHORIZED", timestamp: nil, violations: nil
            ),
            status: 401
        )
    }
}

private struct StubAuthAPI: AuthAPI {
    let log: CallLog

    nonisolated func signUp(email: String, password: String, nickname: String) async throws -> MemberDTO {
        MemberDTO(id: "1", email: email, nickname: nickname)
    }

    nonisolated func logIn(email: String, password: String) async throws -> TokenPairDTO {
        TokenPairDTO(accessToken: "a", refreshToken: "r", tokenType: "Bearer", expiresIn: 1800)
    }

    nonisolated func refresh(refreshToken: String) async throws -> AccessTokenDTO {
        await log.recordRefresh()
        return AccessTokenDTO(accessToken: "newAccess", tokenType: "Bearer", expiresIn: 1800)
    }

    nonisolated func me(accessToken: String) async throws -> MemberDTO {
        MemberDTO(id: "1", email: "user@veritae.app", nickname: "진실이")
    }
}

// MARK: - 테스트

@Suite("AnalysisStore")
@MainActor
struct AnalysisStoreTests {

    private func makeStore(
        api: StubAnalysisAPI,
        log: CallLog,
        tokenStore: InMemoryTokenStore = InMemoryTokenStore(
            initialTokens: StoredTokens(accessToken: "oldAccess", refreshToken: "r1")
        )
    ) -> (AnalysisStore, InMemoryTokenStore) {
        let authStore = AuthStore(api: StubAuthAPI(log: log), tokenStore: tokenStore)
        return (AnalysisStore(api: api, authStore: authStore), tokenStore)
    }

    private var imageInput: AnalysisInput {
        AnalysisInput(
            kind: .photo,
            title: "photo.jpg",
            subtitle: "사진",
            previewImage: nil,
            file: UploadFile(kind: .image, filename: "photo.jpg", contentType: "image/jpeg", data: Data([1, 2, 3]))
        )
    }

    // MARK: 선검증 — 업로드 전에 막는다

    /// 링크는 대응 엔드포인트가 없다. 스토어가 스스로 막아야 한다.
    @Test("file 이 없는 입력은 업로드하지 않는다")
    func linkInputRejectedWithoutUpload() async {
        let log = CallLog()
        let (store, _) = makeStore(api: StubAnalysisAPI(log: log), log: log)

        await store.analyze(AnalysisInput(kind: .link, title: "https://x", subtitle: "링크", previewImage: nil))

        guard case .failed(let error) = store.phase, case .unsupportedInput = error else {
            Issue.record("기대: unsupportedInput, 실제: \(store.phase)")
            return
        }
        #expect(await log.analyzeImageCalls == 0)
    }

    /// HEIC 는 iPhone 기본 촬영 포맷이다 — 서버가 400 을 내기 전에 클라가 막아야 한다.
    @Test("서버가 못 받는 형식은 왕복 없이 막는다")
    func unsupportedTypeRejectedWithoutUpload() async {
        let log = CallLog()
        let (store, _) = makeStore(api: StubAnalysisAPI(log: log), log: log)
        var input = imageInput
        input.file = UploadFile(kind: .image, filename: "p.heic", contentType: "image/heic", data: Data([1]))

        await store.analyze(input)

        guard case .failed = store.phase else {
            Issue.record("기대: failed, 실제: \(store.phase)")
            return
        }
        #expect(await log.analyzeImageCalls == 0)
    }

    // MARK: 성공 경로

    @Test("이미지 분석 결과가 AnalysisRecord 로 매핑된다")
    func imageSuccessMapsToRecord() async {
        let log = CallLog()
        let (store, _) = makeStore(api: StubAnalysisAPI(log: log), log: log)

        await store.analyze(imageInput)

        guard case .finished(let record) = store.phase else {
            Issue.record("기대: finished, 실제: \(store.phase)")
            return
        }
        #expect(record.aiProbability == 0.42)
        #expect(record.model == "spai")
        // SPAI 는 근거를 만들지 않는다.
        #expect(record.aiEvidence.isEmpty)
        // 목 모드가 아니면 사기 위험도는 채워지지 않는다 — 서버에 판정 근거가 없다.
        #expect(record.riskLevel == nil)
        #expect(record.riskEvidence.isEmpty)
    }

    // MARK: 401 → refresh → 1회 재시도 (ADR-0007 / AC-10 / AC-11)

    @Test("401 이면 refresh 후 새 토큰으로 정확히 1회 재시도한다")
    func retriesOnceWithRefreshedToken() async throws {
        let log = CallLog()
        let (store, tokenStore) = makeStore(
            api: StubAnalysisAPI(log: log, failFirstWithUnauthorized: true),
            log: log
        )

        await store.analyze(imageInput)

        guard case .finished = store.phase else {
            Issue.record("기대: finished, 실제: \(store.phase)")
            return
        }
        #expect(await log.refreshCalls == 1)
        #expect(await log.analyzeImageCalls == 2)
        // 재시도는 **갱신된** 토큰으로 가야 한다. 옛 토큰으로 다시 가면 무한히 401 이다.
        #expect(await log.seenTokens == ["oldAccess", "newAccess"])
        // refreshToken 은 회전하지 않으므로 보존돼야 한다 (ADR-0010).
        let loaded = try tokenStore.load()
        let stored = try #require(loaded)
        #expect(stored.refreshToken == "r1")
        #expect(stored.accessToken == "newAccess")
    }

    @Test("저장된 토큰이 없으면 세션 만료로 떨어진다")
    func noTokensMeansSessionExpired() async {
        let log = CallLog()
        let (store, _) = makeStore(api: StubAnalysisAPI(log: log), log: log, tokenStore: InMemoryTokenStore())

        await store.analyze(imageInput)

        guard case .failed(let error) = store.phase, case .sessionExpired = error else {
            Issue.record("기대: sessionExpired, 실제: \(store.phase)")
            return
        }
    }

    // MARK: 영상 job — 계약 위반을 성공으로 위장하지 않는다

    /// 폴링 첫 시도가 2초 뒤라 이 테스트들은 그만큼 걸린다.
    @Test("COMPLETED 인데 aiDetection 이 없으면 성공으로 위장하지 않는다", .timeLimit(.minutes(1)))
    func completedWithoutDetectionIsFailure() async {
        let log = CallLog()
        let api = StubAnalysisAPI(
            log: log,
            jobResponse: AnalysisJobDTO(jobId: "job-1", status: "COMPLETED", aiDetection: nil, errorMessage: nil)
        )
        let (store, _) = makeStore(api: api, log: log)
        var input = imageInput
        input.file = UploadFile(kind: .video, filename: "v.mp4", contentType: "video/mp4", data: Data([1]))

        await store.analyze(input)

        guard case .failed(let error) = store.phase, case .server = error else {
            Issue.record("기대: server, 실제: \(store.phase)")
            return
        }
    }

    /// "얼굴 없음"과 일반 오류를 문자열 매칭으로 가르지 않고 서버 문구를 그대로 노출한다(M4).
    @Test("FAILED 는 서버 errorMessage 를 그대로 보여준다", .timeLimit(.minutes(1)))
    func failedJobSurfacesServerMessage() async {
        let log = CallLog()
        let message = "영상에서 얼굴을 찾을 수 없습니다. 얼굴이 잘 보이는 영상으로 다시 시도해주세요."
        let api = StubAnalysisAPI(
            log: log,
            jobResponse: AnalysisJobDTO(jobId: "job-1", status: "FAILED", aiDetection: nil, errorMessage: message)
        )
        let (store, _) = makeStore(api: api, log: log)
        var input = imageInput
        input.file = UploadFile(kind: .video, filename: "v.mp4", contentType: "video/mp4", data: Data([1]))

        await store.analyze(input)

        guard case .failed(let error) = store.phase else {
            Issue.record("기대: failed, 실제: \(store.phase)")
            return
        }
        #expect(error.errorDescription == message)
        // 파일을 바꿔야 하는 상황이라 재시도 버튼을 띄우지 않는다.
        #expect(!error.isRetryable)
        // 끝난 작업은 폴링 대상에서 빠져야 한다.
        #expect(store.pendingVideoJob == nil)
    }

    @Test("영상 접수 직후 jobId 를 보관한다 — 모달을 닫아도 이어서 폴링하기 위함")
    func videoJobIsRetained() async {
        let log = CallLog()
        // 계속 PROCESSING 을 돌려주는 스텁 — 폴링이 끝나지 않는다.
        let api = StubAnalysisAPI(
            log: log,
            jobResponse: AnalysisJobDTO(jobId: "job-1", status: "PROCESSING", aiDetection: nil, errorMessage: nil)
        )
        let (store, _) = makeStore(api: api, log: log)
        var input = imageInput
        input.file = UploadFile(kind: .video, filename: "v.mp4", contentType: "video/mp4", data: Data([1]))

        // 폴링이 무한하므로 접수 직후 취소해 상태만 확인한다.
        let task = Task { await store.analyze(input) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result

        #expect(await log.submitVideoCalls == 1)
        #expect(store.pendingVideoJob?.id == "job-1")
    }
}
