import Foundation

enum AuthSessionError: Error, Sendable {
    /// Keychain에 유효한 토큰 쌍이 없음(최초 실행 또는 로그아웃 상태).
    case noTokens
}

/// 토큰 보유 + 401 시 refresh 직렬화 + 원 요청 1회 재시도를 담당하는 actor (ADR-0007).
///
/// - refresh는 단일 in-flight `Task`를 공유한다 — 동시 다발 401에서도 실제 네트워크 호출은 1회다(AC-10).
/// - 재시도는 원 요청당 정확히 1회, 재귀하지 않는다(AC-11) — `callMeWithRetry`의 재시도 호출은
///   또 다른 catch 블록으로 감싸지 않으므로 두 번째 401은 그대로 전파된다.
/// - refresh 응답은 `AccessTokenDTO`(refreshToken 없음)로만 받아 accessToken만 갱신하고
///   Keychain의 refreshToken은 절대 덮어쓰지 않는다(ADR-0010).
actor AuthSession {
    enum RestoreResult: Sendable {
        case restored(MemberDTO)
        /// 저장된 토큰이 없거나, refreshToken이 무효(`INVALID_REFRESH_TOKEN`)이거나,
        /// refresh 성공 후 재시도에서도 여전히 `UNAUTHORIZED`인 경우 — 401 계열은 전부 여기로
        /// 모인다(C1 수정). 양쪽 토큰은 이 케이스에 도달하기 전에 이미 삭제된 상태.
        case loggedOut
        /// 401 계열이 **아닌** 오류(오프라인·타임아웃·5xx)만 — 토큰은 보존된다(E11, PRD 미결 2).
        /// `.login`으로 보낼지 재시도 UI를 보일지는 호출부(SplashView)가 결정한다.
        case failed(AuthAPIError)
    }

    private let api: AuthAPI
    private let tokenStore: TokenStoring
    private var refreshTask: Task<AccessTokenDTO, Error>?

    /// `clearTokens()` 호출 횟수. `refreshAccessToken`이 `await` 전후로 이 값을 비교해
    /// **자기가 시작된 뒤 로그아웃이 끼어들었는지**를 판정한다.
    /// `refreshTask?.cancel()`만으로는 부족하다 — 응답을 이미 받아 디코딩까지 끝낸 Task는
    /// 취소에 반응하지 않으므로, 로그아웃 직후 재개된 소유자가 `updateAccessToken`으로
    /// accessToken 항목을 되살릴 수 있다.
    private var clearGeneration = 0

    init(api: AuthAPI, tokenStore: TokenStoring) {
        self.api = api
        self.tokenStore = tokenStore
    }

    /// 로그인 성공 직후 최초 토큰 저장.
    func saveInitialTokens(_ tokens: TokenPairDTO) throws {
        try tokenStore.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
    }

    /// 서버 호출 없음(ADR-0002) — 로그아웃은 로컬 정리로 항상 "성공"하는 기존 계약을 유지한다.
    /// 다만 삭제 실패(M5)는 조용히 삼키지 않고 로그로 표면화한다: 실패하면 다음 실행에서
    /// 토큰이 남아 있을 수 있다는 뜻이라 원인 추적이 가능해야 한다.
    func clearTokens() {
        // 로그아웃 이후 완료되는 in-flight refresh가 accessToken 항목을 재생성하지 못하게 막는다.
        // 취소만으로는 불충분하다(이미 응답을 받은 Task는 취소에 반응하지 않는다) — 그래서
        // 세대 카운터를 올려 `refreshAccessToken`이 재개 시점에 스스로 폐기하도록 한다.
        clearGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        clearTokensSurfacingFailure()
    }

    /// 로그인 직후 `members/me` 호출 — 저장된 토큰으로 401 시 refresh 후 1회 재시도.
    func authorizedMe() async throws -> MemberDTO {
        guard let tokens = try tokenStore.load() else {
            throw AuthSessionError.noTokens
        }
        do {
            return try await callMeWithRetry(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
        } catch let error as AuthAPIError {
            // `restoreSession`과 대칭을 맞춘다 — 재시도까지 마친 뒤에도 401 계열이면 그 토큰은
            // 죽은 것이므로 남겨 두지 않는다. 남기면 방금 받은 무효 토큰이 Keychain에 머물러
            // 다음 실행에서 한 번 더 헛된 복원을 시도한다.
            if isInvalidRefreshToken(error) || isUnauthorized(error) {
                clearTokensSurfacingFailure()
            }
            throw error
        }
    }

    /// 스플래시 세션 복원 전용 진입점 (ADR-0008). 결과를 3분기로 명확히 반환하고,
    /// `phase` 전환은 호출부(AppState/SplashView)가 담당한다 — 이 actor는 화면 상태를 모른다.
    func restoreSession() async -> RestoreResult {
        let tokens: StoredTokens?
        do {
            tokens = try tokenStore.load()
        } catch {
            // Keychain 읽기 자체가 실패(OSStatus 오류) — 세션을 신뢰할 수 없으므로 로그아웃 취급.
            return .loggedOut
        }
        guard let tokens else {
            return .loggedOut
        }
        do {
            let member = try await callMeWithRetry(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
            return .restored(member)
        } catch let error as AuthAPIError {
            // 401 계열 전체를 로그아웃으로 보낸다.
            // - `INVALID_REFRESH_TOKEN`: refresh 자체가 거부됨.
            // - `UNAUTHORIZED`: 대부분 `callMeWithRetry`가 refresh 후 1회 재시도까지 마쳤는데도
            //   여전히 401인 경우다(AC-11). 다만 **항상 "재시도 후" 값은 아니다** —
            //   `/auth/refresh` 가 `INVALID_REFRESH_TOKEN` 대신 `UNAUTHORIZED` 를 던지면
            //   재시도 없이 여기로 온다(스펙상 안 오지만 계약이 보장하지는 않는다).
            //   어느 쪽이든 401 계열로 거부된 세션은 죽은 것이므로 로그아웃이 옳다.
            // 이걸 `.failed`로 보내면 SplashView는 이를 오프라인(E11)으로 오인해 재시도 UI를
            // 띄우지만 토큰은 여전히 무효라서 재시도해도 영원히 같은 결과가 나온다(스플래시 고착).
            if isInvalidRefreshToken(error) || isUnauthorized(error) {
                clearTokensSurfacingFailure()
                return .loggedOut
            }
            // `.failed`는 이제 전송 오류·5xx 등 401이 아닌 실패 전용이다(E11).
            return .failed(error)
        } catch is CancellationError {
            // Minor 1: 취소를 "2xx 스키마 불일치"(.decoding)로 오분류하지 않는다.
            // 이 결과는 대부분 즉시 폐기된다 — 호출부(SplashView.restore)도 `Task.isCancelled`를
            // 별도로 확인한다.
            return .failed(.transport(URLError(.cancelled)))
        } catch {
            return .failed(.decoding(error))
        }
    }

    // MARK: - 인증이 필요한 임의 호출 (analysis 진입점)

    /// 저장된 accessToken으로 `body`를 실행하고, `UNAUTHORIZED` 401이면 refresh 후 **1회만**
    /// 재시도한다. analysis 호출 전부가 이 경로를 통과한다.
    ///
    /// 각 API가 스스로 갱신하게 두면 ADR-0007의 "in-flight refresh는 항상 1개" 불변식이 깨진다 —
    /// 이미지 업로드와 영상 job 폴링이 동시에 401을 받는 상황이 정확히 그 경로다. 이 메서드를
    /// 거치면 동시 호출자들이 `refreshAccessToken`의 단일 in-flight `Task`를 공유한다(AC-10).
    ///
    /// `body`는 `await` 지점이므로 그 사이 로그아웃이 끼어들 수 있다(LL-003). 토큰 재기록은
    /// `refreshAccessToken`의 `clearGeneration` 가드가 막는다 — 로그아웃이 끼어들면 거기서
    /// `CancellationError`로 빠지므로 여기서 따로 검사하지 않는다.
    func withValidAccessToken<T: Sendable>(
        _ body: @Sendable (String) async throws -> T
    ) async throws -> T {
        guard let tokens = try tokenStore.load() else {
            throw AuthSessionError.noTokens
        }
        return try await retrying(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            body
        )
    }

    // MARK: - 내부: 401 → refresh → 1회 재시도

    /// 401 재시도 규율의 **유일한 구현**. `authorizedMe`/`restoreSession`(members/me)과
    /// analysis 호출이 같은 코드를 쓴다 — 두 벌로 두면 한쪽만 고쳐져 갈라진다.
    private func retrying<T: Sendable>(
        accessToken: String,
        refreshToken: String,
        _ body: @Sendable (String) async throws -> T
    ) async throws -> T {
        do {
            return try await body(accessToken)
        } catch let error as AuthAPIError {
            guard isUnauthorized(error) else { throw error }
            let newAccessToken = try await refreshAccessToken(currentRefreshToken: refreshToken)
            // 재시도는 여기서 끝 — 이 호출이 다시 401이어도 재귀하지 않고 그대로 전파한다(AC-11).
            return try await body(newAccessToken)
        }
    }

    private func callMeWithRetry(accessToken: String, refreshToken: String) async throws -> MemberDTO {
        // `api`를 지역 상수로 꺼낸다 — 클로저 본문은 actor 외부에서 실행되므로 그 안에서
        // `self.api`를 읽지 않는다.
        let api = self.api
        return try await retrying(accessToken: accessToken, refreshToken: refreshToken) {
            try await api.me(accessToken: $0)
        }
    }

    private func isUnauthorized(_ error: AuthAPIError) -> Bool {
        guard case .problem(let problem, _) = error, let code = problem.errorCode else { return false }
        return code == KnownErrorCode.unauthorized.rawValue
    }

    private func isInvalidRefreshToken(_ error: AuthAPIError) -> Bool {
        guard case .problem(let problem, _) = error, let code = problem.errorCode else { return false }
        return code == KnownErrorCode.invalidRefreshToken.rawValue
    }

    /// 단일 in-flight `Task` 공유 — 동시 호출자는 이미 진행 중인 refresh 결과를 기다린다(AC-10).
    private func refreshAccessToken(currentRefreshToken: String) async throws -> String {
        if let existing = refreshTask {
            return try await existing.value.accessToken
        }

        let generation = clearGeneration
        let task = Task { () throws -> AccessTokenDTO in
            try await api.refresh(refreshToken: currentRefreshToken)
        }
        refreshTask = task
        // identity 가드가 필수다. `clearTokens()`도 이 슬롯에 쓰기 때문에, 무조건 `nil`을 넣으면
        // 로그아웃 → 재로그인으로 만들어진 **다른** Task를 지워 버리고, 그 뒤 401이 오면
        // 두 번째 refresh Task가 동시에 진행돼 "정확히 1회"(AC-10)가 깨진다.
        // `Task`는 struct 이므로 `===`가 아니라 `==`(Equatable 준수)로 비교한다.
        defer { if refreshTask == task { refreshTask = nil } }

        do {
            let dto = try await task.value
            // 이 `await` 동안 로그아웃이 끼어들었으면 새 accessToken을 저장하지 않는다.
            // 저장하면 로그아웃한 기기에 유효한 accessToken이 남는다(refreshToken 없이).
            guard clearGeneration == generation else {
                throw CancellationError()
            }
            try tokenStore.updateAccessToken(dto.accessToken)
            return dto.accessToken
        } catch let error as AuthAPIError {
            if isInvalidRefreshToken(error) {
                clearTokensSurfacingFailure()
            }
            throw error
        }
    }

    /// `clear()`가 `throws`로 바뀐 뒤(M5) 여러 지점에서 반복되는 "삭제 실패는 삼키지 말고
    /// 로그로 남긴다" 패턴을 한 곳에 모은다.
    private func clearTokensSurfacingFailure() {
        do {
            try tokenStore.clear()
        } catch {
            print("[Veritae][Auth] 경고: 토큰 삭제 실패 — \(error).")
        }
    }
}
