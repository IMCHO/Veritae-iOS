import Foundation
import Security

/// Keychain에 저장된 토큰 쌍. 둘 중 하나만 있으면 손상으로 간주한다(E10) — 이 타입은
/// 항상 "둘 다 있음"만 표현하도록 `TokenStoring.load()`가 보장한다.
struct StoredTokens: Sendable {
    let accessToken: String
    let refreshToken: String
}

enum TokenStoreError: Error, Sendable {
    case unhandledStatus(OSStatus)
}

/// 토큰 저장소 추상화 — 테스트 대역 주입 지점(테스트 타깃은 없지만 프로토콜 경계는 유지, PRD 제약).
///
/// `nonisolated` — 이 프로토콜은 `AuthSession` actor 내부에서 동기 호출된다. 프로젝트가
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`이므로 명시하지 않으면 구현체가 기본적으로
/// MainActor에 격리되어 actor 컨텍스트에서의 동기 호출이 컴파일되지 않는다.
protocol TokenStoring: Sendable {
    nonisolated func load() throws -> StoredTokens?
    nonisolated func save(accessToken: String, refreshToken: String) throws
    nonisolated func updateAccessToken(_ accessToken: String) throws
    /// M5: `throws`다 — 삭제 실패(OSStatus)를 호출부가 삼키지 않고 표면화할 수 있어야 한다.
    /// 조용히 성공한 것처럼 반환하면 AC-12("재실행해도 로그인 화면")를 어길 수 있다.
    nonisolated func clear() throws
}

/// Keychain(`kSecClassGenericPassword`) 기반 구현 (ADR-0006).
///
/// - `kSecAttrAccessible`은 `kSecAttrAccessibleAfterFirstUnlock` — 백그라운드 갱신 가능성을 열어둔다.
/// - iCloud 동기화 off (`kSecAttrSynchronizable` 미설정).
/// - `kSecAttrService`는 번들 ID가 아닌 고정 문자열이다. 번들 ID가 `devplaceholder.*`
///   플레이스홀더라 확정 시 바뀌면, 번들 ID에 묶인 서비스 식별자는 기존 저장 항목을
///   못 찾아 전 사용자가 조용히 로그아웃된다(PRD R8).
struct KeychainTokenStore: TokenStoring {
    private nonisolated static let service = "app.veritae.auth"
    private nonisolated static let accessTokenAccount = "accessToken"
    private nonisolated static let refreshTokenAccount = "refreshToken"

    // 합성 memberwise init은 모듈 기본(MainActor) 격리를 물려받는다. 이 타입은 어디서든
    // (actor 포함) 동기적으로 생성 가능해야 하므로 명시적으로 nonisolated init을 둔다.
    nonisolated init() {}

    nonisolated func load() throws -> StoredTokens? {
        let access = try readItem(account: Self.accessTokenAccount)
        let refresh = try readItem(account: Self.refreshTokenAccount)
        switch (access, refresh) {
        case let (access?, refresh?):
            return StoredTokens(accessToken: access, refreshToken: refresh)
        case (nil, nil):
            return nil
        default:
            // 부분 손상(E10) — 복구 불가능한 상태로 보고 양쪽을 삭제한다.
            try clear()
            return nil
        }
    }

    nonisolated func save(accessToken: String, refreshToken: String) throws {
        try writeItem(account: Self.accessTokenAccount, value: accessToken)
        try writeItem(account: Self.refreshTokenAccount, value: refreshToken)
    }

    nonisolated func updateAccessToken(_ accessToken: String) throws {
        // refresh 응답 갱신 전용 — refreshToken 계정은 절대 건드리지 않는다 (ADR-0007/0010).
        try writeItem(account: Self.accessTokenAccount, value: accessToken)
    }

    nonisolated func clear() throws {
        try deleteItem(account: Self.accessTokenAccount)
        try deleteItem(account: Self.refreshTokenAccount)
    }

    // MARK: - Keychain 원시 접근

    private nonisolated func readItem(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            // 저장 실패를 삼키지 않는다 — "로그인은 됐는데 재시작하면 풀림" 같은 재현 어려운
            // 버그를 막기 위해 반드시 오류로 표면화한다 (ADR-0006).
            throw TokenStoreError.unhandledStatus(status)
        }
    }

    private nonisolated func writeItem(account: String, value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.unhandledStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw TokenStoreError.unhandledStatus(updateStatus)
        }
    }

    /// M5: `errSecItemNotFound`(이미 없음 — 목표 상태 달성)만 정상 취급하고, 그 외 OSStatus는
    /// 표면화한다. 예전엔 `SecItemDelete`의 반환값을 버려서 삭제 실패가 성공처럼 보였다.
    private nonisolated func deleteItem(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.unhandledStatus(status)
        }
    }

    private nonisolated func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            // Minor 6: `SUPPORTED_PLATFORMS`에 macosx가 포함돼 있다. macOS에서 이 키 없이
            // legacy(파일 기반) keychain을 쓰면 `kSecAttrAccessibleAfterFirstUnlock`이 무시될
            // 수 있다(추론 — 실측은 후속). iOS에는 무해하므로 키만 추가해 둔다.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

#if DEBUG
/// 인메모리 `TokenStoring` 대역 (M8). `TokenStoring`이 "테스트 대역 주입 지점"이라고 선언한
/// 계약을 실제로 충족시킨다 — 프리뷰가 실 Keychain에 묶이지 않게 한다.
/// 테스트 타깃은 없지만(리포 제약) 이 타입 자체는 향후 타깃 신설 시 그대로 재사용 가능하다.
final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    // `nonisolated(unsafe)`: 이 프로퍼티는 Swift의 격리가 아니라 `lock`으로 직접 동기화한다
    // (M1과 같은 이유 — 모듈 기본 MainActor 격리 하에서는 `var` 저장 프로퍼티가 기본적으로
    // MainActor로 격리 추론된다. 실측 확인).
    private nonisolated(unsafe) var tokens: StoredTokens?

    nonisolated init(initialTokens: StoredTokens? = nil) {
        self.tokens = initialTokens
    }

    nonisolated func load() throws -> StoredTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    nonisolated func save(accessToken: String, refreshToken: String) throws {
        lock.lock()
        defer { lock.unlock() }
        tokens = StoredTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    nonisolated func updateAccessToken(_ accessToken: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let current = tokens else { return }
        tokens = StoredTokens(accessToken: accessToken, refreshToken: current.refreshToken)
    }

    nonisolated func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        tokens = nil
    }
}
#endif
