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
    var recordsCalls = 0
    var reportCalls = 0
    /// analyze 가 받은 accessToken 순서 — 재시도가 **새 토큰으로** 갔는지 확인한다.
    var seenTokens: [String] = []

    func recordAnalyzeImage(token: String) -> Int {
        analyzeImageCalls += 1
        seenTokens.append(token)
        return analyzeImageCalls
    }

    func recordSubmitVideo() { submitVideoCalls += 1 }
    func recordRecords(token: String) -> Int { recordsCalls += 1; seenTokens.append(token); return recordsCalls }
    func recordReport(token: String) -> Int { reportCalls += 1; seenTokens.append(token); return reportCalls }
    func recordJob() -> Int { jobCalls += 1; return jobCalls }
    func recordRefresh() { refreshCalls += 1 }
}

private struct StubAnalysisAPI: AnalysisAPI {
    let log: CallLog
    /// 첫 호출을 401 UNAUTHORIZED 로 실패시킨다.
    var failFirstWithUnauthorized = false
    /// `job(id:)` 이 돌려줄 상태·본문.
    var jobResponse: AnalysisJobDTO?
    /// image/audio 응답의 `scamDetection`. 기본 `nil` = 키 부재(텍스트 없음).
    var scam: ScamDetectionDTO?
    /// `records()` 가 돌려줄 목록 / 던질 오류 / 응답 전 대기.
    var recordsResponse: [AnalysisRecordDTO] = []
    var recordsError: AuthAPIError?
    var recordsDelay: Duration?

    nonisolated func analyzeImage(_ file: UploadFile, accessToken: String) async throws -> ImageAnalysisResponseDTO {
        let count = await log.recordAnalyzeImage(token: accessToken)
        if failFirstWithUnauthorized, count == 1 {
            throw Self.unauthorized()
        }
        return ImageAnalysisResponseDTO(
            aiDetection: ImageDetectionDTO(model: "spai", score: 0.42, evidenceImage: nil),
            scamDetection: scam
        )
    }

    nonisolated func analyzeAudio(_ file: UploadFile, accessToken: String) async throws -> AudioAnalysisResponseDTO {
        AudioAnalysisResponseDTO(
            aiDetection: AudioDetectionDTO(model: "antideepfake", score: 0.1, evidence: []),
            scamDetection: scam
        )
    }

    nonisolated func submitVideo(_ file: UploadFile, accessToken: String) async throws -> String {
        await log.recordSubmitVideo()
        return "job-1"
    }

    nonisolated func job(id: String, accessToken: String) async throws -> AnalysisJobDTO {
        _ = await log.recordJob()
        return jobResponse ?? Self.job(status: "COMPLETED")
    }

    nonisolated func records(accessToken: String) async throws -> [AnalysisRecordDTO] {
        let count = await log.recordRecords(token: accessToken)
        if let recordsDelay {
            try await Task.sleep(for: recordsDelay)
        }
        if failFirstWithUnauthorized, count == 1 {
            throw Self.unauthorized()
        }
        if let recordsError {
            throw recordsError
        }
        return recordsResponse
    }

    nonisolated func report(accessToken: String) async throws -> AnalysisReportDTO {
        let count = await log.recordReport(token: accessToken)
        if failFirstWithUnauthorized, count == 1 {
            throw Self.unauthorized()
        }
        return AnalysisReportDTO(
            totalCount: 23, imageCount: 10, audioCount: 8, videoCount: 5,
            aiDetectedCount: 3, scamDetectedCount: 2
        )
    }

    nonisolated static func job(
        status: String,
        ai: VideoDetectionDTO? = nil,
        scam: ScamDetectionDTO? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) -> AnalysisJobDTO {
        AnalysisJobDTO(
            jobId: "job-1", status: status, aiDetection: ai, scamDetection: scam,
            errorCode: errorCode, errorMessage: errorMessage
        )
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

/// `.serialized` — 이 스위트의 일부 테스트가 `AppConfig.isMockModeEnabled`(UserDefaults 전역)를
/// 건드린다. 병렬로 돌면 서로의 설정을 덮어써 산발적으로 실패한다.
@Suite("AnalysisStore", .serialized)
@MainActor
struct AnalysisStoreTests {

    /// 목 모드 플래그를 강제하고 원래 값으로 되돌린다.
    ///
    /// **이게 없으면 테스트 결과가 "시뮬레이터에서 마지막으로 누른 토글"에 좌우된다.**
    /// 실제로 겪었다 — 디버그 오버레이로 목 모드를 켜 둔 뒤 테스트를 돌리자
    /// `riskLevel == nil` 단언이 깨졌다. 앱 컨테이너의 UserDefaults 를 테스트 프로세스가
    /// 그대로 공유하기 때문이다.
    private func withMockMode<T>(_ enabled: Bool, _ body: () async -> T) async -> T {
        let previous = AppConfig.isMockModeEnabled
        AppConfig.isMockModeEnabled = enabled
        defer { AppConfig.isMockModeEnabled = previous }
        return await body()
    }

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
        #expect(record.modality == .image)
        #expect(record.input != nil)
        // SPAI 는 근거를 만들지 않는다.
        #expect(record.aiEvidence.isEmpty)
        // `scamDetection` 키가 없다 = 텍스트가 없었다 → 사기 위험도 카드를 숨긴다.
        #expect(record.riskLevel == nil)
        #expect(record.riskEvidence.isEmpty)
        #expect(record.notice == nil)
    }

    /// 예전에는 목 모드에서만 데모용 위험도를 지어냈다(`demoRiskLevel`). 그 코드가 되살아나면
    /// 서버가 "텍스트 없음"이라고 한 결과에 근거 없는 판정이 붙는다 — 목 플래그를 켜고도 `nil` 인지 고정한다.
    @Test("사기 위험도는 목 모드 플래그와 무관하게 서버 scamDetection 에서만 온다")
    func riskLevelNeverInventedInMockMode() async {
        let log = CallLog()
        let (store, _) = makeStore(api: StubAnalysisAPI(log: log), log: log)

        await withMockMode(true) { await store.analyze(imageInput) }

        guard case .finished(let record) = store.phase else {
            Issue.record("기대: finished, 실제: \(store.phase)")
            return
        }
        #expect(record.riskLevel == nil)
    }

    @Test("scamDetection 이 있으면 위험도·근거 문장으로 매핑된다")
    func scamDetectionMapsToRisk() async {
        let log = CallLog()
        let scam = ScamDetectionDTO(
            model: "lilju",
            score: 0.82,
            evidence: [
                ScamEvidenceDTO(sentence: "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", score: 0.95),
                ScamEvidenceDTO(sentence: "괜찮습니다.", score: 0.1),
            ]
        )
        let (store, _) = makeStore(api: StubAnalysisAPI(log: log, scam: scam), log: log)

        await store.analyze(imageInput)

        guard case .finished(let record) = store.phase else {
            Issue.record("기대: finished, 실제: \(store.phase)")
            return
        }
        #expect(record.riskLevel == .high)
        #expect(record.riskEvidence.map(\.title) == [
            "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", "괜찮습니다.",
        ])
        // 문장별 심각도는 서버가 준 점수다 — 같은 임계값으로 옮긴다.
        #expect(record.riskEvidence.map(\.severity) == [.high, .low])
        #expect(record.riskEvidence.allSatisfy { $0.timeRange == nil })
    }

    @Test("음성도 scamDetection 을 전달한다")
    func audioCarriesScamDetection() async {
        let log = CallLog()
        let scam = ScamDetectionDTO(model: "lilju", score: 0.5, evidence: nil)
        let (store, _) = makeStore(api: StubAnalysisAPI(log: log, scam: scam), log: log)
        var input = imageInput
        input.file = UploadFile(kind: .audio, filename: "a.m4a", contentType: "audio/mp4", data: Data([1]))

        await store.analyze(input)

        guard case .finished(let record) = store.phase else {
            Issue.record("기대: finished, 실제: \(store.phase)")
            return
        }
        #expect(record.modality == .audio)
        #expect(record.riskLevel == .medium)
        // evidence 키가 없어도 점수는 살린다.
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

    // MARK: 영상 job — status 먼저, 그다음 필드 존재로 (ADR-0018)

    private var videoInput: AnalysisInput {
        var input = imageInput
        input.file = UploadFile(kind: .video, filename: "v.mp4", contentType: "video/mp4", data: Data([1]))
        return input
    }

    private static let noFaceMessage =
        "영상에서 얼굴을 찾을 수 없어 AI판독은 제공되지 않습니다. 얼굴이 잘 보이는 영상이면 판독도 함께 받을 수 있습니다."

    /// 회귀: 예전 코드는 `COMPLETED && aiDetection == nil` 을 계약 위반으로 보고 일반 오류를 띄워,
    /// 유효한 사기 탐지 결과를 버렸다. 폴링 첫 시도가 2초 뒤라 이 테스트들은 그만큼 걸린다.
    @Test("얼굴 없음(COMPLETED + NO_FACE_DETECTED)은 실패가 아니라 결과로 끝난다", .timeLimit(.minutes(1)))
    func noFaceCompletedIsResult() async {
        let log = CallLog()
        let api = StubAnalysisAPI(
            log: log,
            jobResponse: StubAnalysisAPI.job(
                status: "COMPLETED",
                scam: ScamDetectionDTO(
                    model: "lilju", score: 0.82,
                    evidence: [ScamEvidenceDTO(sentence: "지금 바로 계좌번호와 비밀번호를 알려주셔야 합니다.", score: 0.95)]
                ),
                errorCode: "NO_FACE_DETECTED",
                errorMessage: Self.noFaceMessage
            )
        )
        let (store, _) = makeStore(api: api, log: log)

        await store.analyze(videoInput)

        guard case .finished(let record) = store.phase else {
            Issue.record("기대: finished, 실제: \(store.phase)")
            return
        }
        // AI 판독 없음 — 0 으로 채우면 "AI 아님" 이라는 거짓 판정이 된다.
        #expect(record.aiProbability == nil)
        #expect(record.aiLevel == nil)
        #expect(record.model == nil)
        #expect(record.aiEvidence.isEmpty)
        // 사기 탐지 결과는 살아 있다.
        #expect(record.riskLevel == .high)
        #expect(record.riskEvidence.count == 1)
        // 서버 문구를 그대로 보여준다.
        #expect(record.notice == Self.noFaceMessage)
        #expect(store.pendingVideoJob == nil)
    }

    /// 사유 없이 둘 다 비었다 — 보여줄 것도, 비어 있는 이유도 없다. 빈 결과로 성공을 위장하지 않는다.
    @Test("COMPLETED 인데 aiDetection·scamDetection·errorCode 가 모두 없으면 실패로 본다", .timeLimit(.minutes(1)))
    func completedWithNothingIsFailure() async {
        let log = CallLog()
        let api = StubAnalysisAPI(log: log, jobResponse: StubAnalysisAPI.job(status: "COMPLETED"))
        let (store, _) = makeStore(api: api, log: log)

        await store.analyze(videoInput)

        guard case .failed(let error) = store.phase, case .server = error else {
            Issue.record("기대: server, 실제: \(store.phase)")
            return
        }
        #expect(error.isRetryable)
        #expect(store.pendingVideoJob == nil)
    }

    /// 얼굴도 없고 발화도 없는 영상 — 둘 다 정상적으로 비었다. 사유가 있으니 결과로 끝낸다.
    @Test("둘 다 없어도 errorCode 가 있으면 사유 문구만 있는 결과로 끝난다")
    func completedWithNothingButReasonIsResult() {
        let phase = AnalysisStore.completedPhase(
            for: StubAnalysisAPI.job(status: "COMPLETED", errorCode: "NO_FACE_DETECTED", errorMessage: Self.noFaceMessage),
            input: videoInput
        )
        guard case .finished(let record) = phase else {
            Issue.record("기대: finished, 실제: \(phase)")
            return
        }
        #expect(record.aiProbability == nil)
        #expect(record.riskLevel == nil)
        #expect(record.notice == Self.noFaceMessage)
    }

    @Test("서버 문구가 빠져도 errorCode 로 고른 안내가 붙는다")
    func noticeFallsBackToErrorCode() {
        let phase = AnalysisStore.completedPhase(
            for: StubAnalysisAPI.job(status: "COMPLETED", errorCode: "NO_FACE_DETECTED"),
            input: videoInput
        )
        guard case .finished(let record) = phase else {
            Issue.record("기대: finished, 실제: \(phase)")
            return
        }
        #expect(record.notice == AnalysisRecord.missingAINotice(errorCode: "NO_FACE_DETECTED"))
        #expect(record.notice != AnalysisRecord.missingAINotice(errorCode: nil))
    }

    /// errorCode 는 열린 집합이다. 모르는 코드여도 COMPLETED 면 있는 필드로 화면을 만든다.
    @Test("미지 job errorCode + COMPLETED 는 있는 필드만으로 결과를 만든다")
    func unknownErrorCodeCompletedUsesAvailableFields() {
        let withAI = AnalysisStore.completedPhase(
            for: StubAnalysisAPI.job(
                status: "COMPLETED",
                ai: VideoDetectionDTO(model: "dfdc", score: 0.91, evidence: [], evidenceImage: nil),
                errorCode: "SOMETHING_NEW",
                errorMessage: "일부 판독이 제공되지 않았습니다."
            ),
            input: videoInput
        )
        guard case .finished(let record) = withAI else {
            Issue.record("기대: finished, 실제: \(withAI)")
            return
        }
        #expect(record.aiProbability == 0.91)
        #expect(record.riskLevel == nil)
        #expect(record.notice == "일부 판독이 제공되지 않았습니다.")

        let scamOnly = AnalysisStore.completedPhase(
            for: StubAnalysisAPI.job(
                status: "COMPLETED",
                scam: ScamDetectionDTO(model: "lilju", score: 0.1, evidence: []),
                errorCode: "SOMETHING_NEW"
            ),
            input: videoInput
        )
        guard case .finished(let scamRecord) = scamOnly else {
            Issue.record("기대: finished, 실제: \(scamOnly)")
            return
        }
        #expect(scamRecord.aiProbability == nil)
        #expect(scamRecord.riskLevel == .low)
        // 미지 코드 — 특정 사유를 지어내지 않고 일반 안내로 떨어진다.
        #expect(scamRecord.notice == AnalysisRecord.missingAINotice(errorCode: nil))
    }

    /// 명세: ANALYSIS_FAILED 는 "같은 영상으로 재시도 가능". 기존 실패 화면의 "다시 시도" 를 연다.
    @Test("FAILED + ANALYSIS_FAILED 는 서버 문구를 보여주고 재시도를 연다", .timeLimit(.minutes(1)))
    func analysisFailedIsRetryable() async {
        let log = CallLog()
        let api = StubAnalysisAPI(
            log: log,
            jobResponse: StubAnalysisAPI.job(
                status: "FAILED", errorCode: "ANALYSIS_FAILED", errorMessage: "영상 분석 중 오류가 발생했습니다."
            )
        )
        let (store, _) = makeStore(api: api, log: log)

        await store.analyze(videoInput)

        guard case .failed(let error) = store.phase, case .jobFailed = error else {
            Issue.record("기대: jobFailed, 실제: \(store.phase)")
            return
        }
        #expect(error.errorDescription == "영상 분석 중 오류가 발생했습니다.")
        #expect(error.isRetryable)
        // 끝난 작업은 폴링 대상에서 빠져야 한다 — 재시도는 새 접수다.
        #expect(store.pendingVideoJob == nil)
    }

    /// N1: AI 판독만 이유 없이 빠지고 사기 탐지만 온 COMPLETED. 게이지도 설명도 없이 사기 카드만 남으면
    /// 사용자가 AI 판독이 왜 빠졌는지 모른다 — 이유를 단정하지 않는 기본 안내가 붙어야 한다.
    @Test("AI 판독이 errorCode·errorMessage 없이 빠지면 단정하지 않는 기본 안내가 붙는다")
    func missingAIWithoutReasonGetsNeutralNotice() {
        let phase = AnalysisStore.completedPhase(
            for: StubAnalysisAPI.job(status: "COMPLETED", scam: ScamDetectionDTO(model: "lilju", score: 0.82, evidence: [])),
            input: videoInput
        )
        guard case .finished(let record) = phase else {
            Issue.record("기대: finished, 실제: \(phase)")
            return
        }
        let neutral = AnalysisRecord.missingAINotice(errorCode: nil)
        #expect(record.aiProbability == nil)
        #expect(record.riskLevel == .high)
        #expect(record.displayedNotice == neutral)
        // 얼굴 없음처럼 특정 이유를 지어내지 않는다.
        #expect(record.displayedNotice != AnalysisRecord.missingAINotice(errorCode: "NO_FACE_DETECTED"))

        // 매핑을 거치지 않고 만든 기록(notice 없음)도 화면에서는 같은 안내가 뜬다.
        var bare = record
        bare.notice = nil
        #expect(bare.displayedNotice == neutral)
        // AI 판독이 있고 사유도 없으면 안내 카드는 없다.
        bare.aiProbability = 0.3
        #expect(bare.displayedNotice == nil)
    }

    /// m4: 명세 "같은 영상으로 재시도 가능". 기존 실패 화면의 "다시 시도" 는 같은 입력으로 `analyze` 를 다시 부른다 —
    /// 폴링 대상이 비워졌으므로 **새로 접수**돼야 한다(옛 job 을 다시 폴링하지 않는다).
    @Test("ANALYSIS_FAILED 후 같은 입력으로 재시도하면 새로 접수한다", .timeLimit(.minutes(1)))
    func analysisFailedRetryResubmits() async {
        let log = CallLog()
        let api = StubAnalysisAPI(
            log: log,
            jobResponse: StubAnalysisAPI.job(status: "FAILED", errorCode: "ANALYSIS_FAILED", errorMessage: "영상 분석 중 오류가 발생했습니다.")
        )
        let (store, _) = makeStore(api: api, log: log)

        await store.analyze(videoInput)
        guard case .failed(let error) = store.phase, error.isRetryable else {
            Issue.record("기대: 재시도 가능한 실패, 실제: \(store.phase)")
            return
        }
        #expect(store.pendingVideoJob == nil)

        await store.analyze(videoInput)

        #expect(await log.submitVideoCalls == 2)
        #expect(await log.jobCalls == 2)
    }

    /// 명세 7p: "status가 FAILED이면 aiDetection/scamDetection 둘 다 없다." 와도 결과로 쓰지 않는다.
    @Test("FAILED 에 판독 필드가 섞여 와도 결과로 쓰지 않는다", .timeLimit(.minutes(1)))
    func failedIgnoresDetectionFields() async {
        let log = CallLog()
        let api = StubAnalysisAPI(
            log: log,
            jobResponse: StubAnalysisAPI.job(
                status: "FAILED",
                ai: VideoDetectionDTO(model: "dfdc", score: 0.91, evidence: [], evidenceImage: nil),
                scam: ScamDetectionDTO(model: "lilju", score: 0.82, evidence: []),
                errorCode: "ANALYSIS_FAILED",
                errorMessage: "영상 분석 중 오류가 발생했습니다."
            )
        )
        let (store, _) = makeStore(api: api, log: log)

        await store.analyze(videoInput)

        guard case .failed(let error) = store.phase, case .jobFailed = error else {
            Issue.record("기대: jobFailed, 실제: \(store.phase)")
            return
        }
    }

    @Test("FAILED 의 errorCode 가 없거나 미지면 재시도를 약속하지 않는다", arguments: [nil, "SOMETHING_NEW"] as [String?])
    func failedWithoutKnownCodeIsNotRetryable(code: String?) {
        let error = AnalysisStore.failure(
            for: StubAnalysisAPI.job(status: "FAILED", errorCode: code, errorMessage: "실패했습니다.")
        )
        #expect(error.errorDescription == "실패했습니다.")
        #expect(!error.isRetryable)
    }

    @Test("FAILED 에 서버 문구가 없으면 기본 문구")
    func failedWithoutMessageUsesDefault() {
        let error = AnalysisStore.failure(for: StubAnalysisAPI.job(status: "FAILED", errorCode: "ANALYSIS_FAILED"))
        #expect(error.errorDescription == "영상 분석에 실패했습니다.")
    }

    @Test("영상 접수 직후 jobId 를 보관한다 — 모달을 닫아도 이어서 폴링하기 위함")
    func videoJobIsRetained() async {
        let log = CallLog()
        // 계속 PROCESSING 을 돌려주는 스텁 — 폴링이 끝나지 않는다.
        let api = StubAnalysisAPI(
            log: log,
            jobResponse: StubAnalysisAPI.job(status: "PROCESSING")
        )
        let (store, _) = makeStore(api: api, log: log)
        let input = videoInput

        // 폴링이 무한하므로 접수 직후 취소해 상태만 확인한다.
        let task = Task { await store.analyze(input) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result

        #expect(await log.submitVideoCalls == 1)
        #expect(store.pendingVideoJob?.id == "job-1")
    }
}

// MARK: - 기록(서버 정본) · 통계

/// 계정 화면 기록은 서버(`GET /analysis/records`)가 정본이다(ADR-0017).
@Suite("AnalysisHistoryStore")
@MainActor
struct AnalysisHistoryStoreTests {

    private func makeStore(
        api: StubAnalysisAPI,
        log: CallLog
    ) -> (AnalysisHistoryStore, AuthStore) {
        let authStore = AuthStore(
            api: StubAuthAPI(log: log),
            tokenStore: InMemoryTokenStore(initialTokens: StoredTokens(accessToken: "oldAccess", refreshToken: "r1"))
        )
        return (AnalysisHistoryStore(api: api, authStore: authStore), authStore)
    }

    private func item(_ id: String, modality: String) -> AnalysisRecordDTO {
        AnalysisRecordDTO(
            id: id,
            modality: modality,
            createdAt: "2026-09-23T09:00:00Z",
            imageDetection: ImageDetectionDTO(model: "spai", score: 0.87, evidenceImage: nil),
            audioDetection: nil,
            videoDetection: nil,
            scamDetection: nil,
            errorCode: nil
        )
    }

    @Test("서버 순서를 유지하고 미지 modality 는 건너뛴다")
    func loadMapsAndSkipsUnknownModality() async {
        let log = CallLog()
        let api = StubAnalysisAPI(
            log: log,
            recordsResponse: [item("a", modality: "IMAGE"), item("x", modality: "TEXT"), item("b", modality: "IMAGE")]
        )
        let (store, _) = makeStore(api: api, log: log)

        await store.load()

        #expect(store.records?.map(\.id) == ["a", "b"])
        // 서버 기록은 원본 미디어가 없다.
        #expect(store.records?.allSatisfy { $0.input == nil } == true)
        #expect(store.loadError == nil)
        #expect(!store.isLoading)
    }

    @Test("빈 목록은 nil 이 아니라 빈 배열이다 — 로딩과 '기록 없음'을 구분한다")
    func emptyListIsDistinctFromNotLoaded() async {
        let log = CallLog()
        let (store, _) = makeStore(api: StubAnalysisAPI(log: log), log: log)
        #expect(store.records == nil)

        await store.load()

        #expect(store.records?.isEmpty == true)
    }

    @Test("records 도 401 이면 refresh 후 새 토큰으로 1회 재시도한다")
    func recordsRetriesOnceWithRefreshedToken() async {
        let log = CallLog()
        let api = StubAnalysisAPI(log: log, failFirstWithUnauthorized: true, recordsResponse: [item("a", modality: "IMAGE")])
        let (store, _) = makeStore(api: api, log: log)

        await store.load()

        #expect(store.records?.map(\.id) == ["a"])
        #expect(await log.refreshCalls == 1)
        #expect(await log.recordsCalls == 2)
        #expect(await log.seenTokens == ["oldAccess", "newAccess"])
    }

    @Test("실패하면 오류 상태가 되고 재시도할 수 있다")
    func failureSetsError() async {
        let log = CallLog()
        let api = StubAnalysisAPI(log: log, recordsError: .http(status: 500))
        let (store, _) = makeStore(api: api, log: log)

        await store.load()

        guard case .server = store.loadError else {
            Issue.record("기대: server, 실제: \(String(describing: store.loadError))")
            return
        }
        #expect(store.loadError?.isRetryable == true)
        #expect(store.records == nil)
        #expect(!store.isLoading)
    }

    /// LL-003: 불러오는 도중 로그아웃하면, 재개된 응답이 다음 사용자의 화면에 앞 계정 기록을 채우면 안 된다.
    @Test("불러오는 중에 clear() 되면 늦게 온 응답을 버린다")
    func clearDuringLoadDiscardsResult() async {
        let log = CallLog()
        let api = StubAnalysisAPI(log: log, recordsResponse: [item("a", modality: "IMAGE")], recordsDelay: .milliseconds(300))
        let (store, _) = makeStore(api: api, log: log)

        let task = Task { await store.load() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.isLoading)
        store.clear()
        await task.value

        #expect(store.records == nil)
        #expect(store.loadError == nil)
        #expect(!store.isLoading)
    }

    /// LL-001: 화면 이탈(호출자 취소)은 "네트워크 오류"가 아니다. 요청은 호출자와 수명이 분리돼 끝까지 가고,
    /// 그 결과가 다음 진입에 쓰인다.
    @Test("호출자가 취소돼도 오류를 띄우지 않고 요청은 끝까지 가서 목록을 채운다")
    func callerCancellationIsSilent() async {
        let log = CallLog()
        let api = StubAnalysisAPI(log: log, recordsResponse: [item("a", modality: "IMAGE")], recordsDelay: .milliseconds(300))
        let (store, _) = makeStore(api: api, log: log)

        let task = Task { await store.load() }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value
        #expect(store.loadError == nil)

        // 다음 진입은 끝난 요청의 결과를 보거나, 진행 중이면 그것을 기다린다 — 요청을 새로 보내지 않는다.
        await store.load()
        #expect(store.records?.map(\.id) == ["a"])
        #expect(store.loadError == nil)
        #expect(!store.isLoading)
    }

    /// m1: 시트를 빠르게 닫았다 다시 연 경우. 예전에는 두 번째 호출이 `isLoading` 을 보고 바로 빠졌고,
    /// 첫 호출이 취소되며 아무것도 쓰지 않아 **스피너가 영구히 멈췄다.**
    @Test("로딩 중 두 번째 load() 후 첫 호출이 취소돼도 두 번째 호출이 결과를 받는다")
    func secondLoadSurvivesFirstCallerCancellation() async {
        let log = CallLog()
        let api = StubAnalysisAPI(log: log, recordsResponse: [item("a", modality: "IMAGE")], recordsDelay: .milliseconds(300))
        let (store, _) = makeStore(api: api, log: log)

        let first = Task { await store.load() }
        try? await Task.sleep(for: .milliseconds(50))
        let second = Task { await store.load() }
        try? await Task.sleep(for: .milliseconds(50))
        first.cancel()
        await second.value
        await first.value

        #expect(store.records?.map(\.id) == ["a"])
        #expect(!store.isLoading)
        #expect(store.loadError == nil)
        // 같은 요청을 공유한다 — 두 번 보내지 않는다.
        #expect(await log.recordsCalls == 1)

        // 끝난 뒤의 호출은 새로 불러온다(방금 끝난 분석을 반영하기 위해).
        await store.load()
        #expect(await log.recordsCalls == 2)
    }

    /// M1: 받은 항목이 전부 미지 modality 면 "기록 없음"이 아니라 오류 + 재시도다.
    @Test("항목이 전부 미지 modality 면 빈 목록이 아니라 오류 상태가 된다")
    func allUnknownModalityIsError() async {
        let log = CallLog()
        let api = StubAnalysisAPI(log: log, recordsResponse: [item("x", modality: "image"), item("y", modality: "TEXT")])
        let (store, _) = makeStore(api: api, log: log)

        await store.load()

        #expect(store.records == nil)
        guard case .server = store.loadError else {
            Issue.record("기대: server, 실제: \(String(describing: store.loadError))")
            return
        }
        #expect(store.loadError?.isRetryable == true)
    }

    /// report 는 아직 스토어·화면에 연결하지 않았다(다음 작업). 대신 같은 인증 경로를 탄다는 것을 고정한다.
    @Test("report 도 withValidAccessToken 경로에서 401 → refresh → 1회 재시도된다")
    func reportRetriesOnceWithRefreshedToken() async throws {
        let log = CallLog()
        let api = StubAnalysisAPI(log: log, failFirstWithUnauthorized: true)
        let (_, authStore) = makeStore(api: api, log: log)

        let report = try await authStore.withValidAccessToken { token in
            try await api.report(accessToken: token)
        }

        #expect(report.totalCount == 23)
        #expect(await log.reportCalls == 2)
        #expect(await log.seenTokens == ["oldAccess", "newAccess"])
    }
}
