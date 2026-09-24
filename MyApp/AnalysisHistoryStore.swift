import Foundation
import Observation

/// 계정 화면의 분석 기록. **정본은 서버(`GET /analysis/records`)다** — 로컬에 기록을 쌓지 않는다(ADR-0017).
///
/// 예전에는 `AppState.records`(메모리)에 방금 끝난 결과를 끼워 넣었다. 그래서 재실행하면 기록이
/// 사라졌고, 다른 기기에서 한 분석은 보이지 않았다. 이제 화면에 들어올 때마다 서버에서 불러온다 —
/// 방금 끝난 분석도 서버가 완료 기록으로 돌려주므로 따로 끼워 넣지 않는다.
///
/// 서버는 완료분 최신순 **최대 10건**만 주고 원본 미디어는 주지 않는다. 그래서 여기서 만든
/// `AnalysisRecord` 는 전부 `input == nil` 이다.
@MainActor
@Observable
final class AnalysisHistoryStore {
    /// `nil` = 아직 한 번도 받지 못했다(로딩 표시). 빈 배열 = 기록 없음.
    private(set) var records: [AnalysisRecord]?
    private(set) var isLoading = false
    /// 마지막 불러오기의 실패. 성공하면 지운다.
    private(set) var loadError: AnalysisError?

    private let api: AnalysisAPI
    private let authStore: AuthStore
    /// `clear()` 가 올린다. 불러오는 도중 로그아웃하면, 재개된 응답이 **다른 사람의 화면에**
    /// 앞 계정의 기록을 채워 넣지 않도록 `await` 이후에 이 값을 다시 확인한다(LL-003).
    private var generation = 0
    /// 진행 중인 불러오기. 호출자(시트의 `.task`)와 **수명을 분리**해 둔다.
    ///
    /// 예전에는 `guard !isLoading else { return }` 으로 두 번째 호출을 버렸다. 시트를 닫으면 첫 호출이
    /// 취소되고 아무것도 쓰지 않은 채 끝나서, 곧바로 다시 연 시트는 **스피너가 멈추거나 옛 목록**을 봤다
    /// (토큰 만료로 refresh 를 기다리는 중이면 흔하다). 이제 요청은 호출자와 별개의 `Task` 로 돌고,
    /// 늦게 온 호출은 같은 요청을 기다린다. 시트가 닫혀도 요청은 끝까지 가서 다음 진입에 쓰인다.
    private var inFlight: (generation: Int, task: Task<Void, Never>)?

    init(api: AnalysisAPI, authStore: AuthStore) {
        self.api = api
        self.authStore = authStore
    }

    /// 서버 기록을 불러온다. 이미 불러오는 중이면 그 요청이 끝날 때까지 기다린다.
    ///
    /// 불러오는 동안 이전 목록을 그대로 보여준다(깜빡임 없음). 실패하면 `loadError` 를 세운다.
    /// 인증은 `withValidAccessToken` 을 거쳐 401 → refresh → 1회 재시도가 적용된다.
    func load() async {
        if let inFlight, inFlight.generation == generation {
            await inFlight.task.value
            return
        }
        let started = generation
        let task = Task { await self.fetch(generation: started) }
        inFlight = (started, task)
        await task.value
    }

    private func fetch(generation started: Int) async {
        isLoading = true
        loadError = nil
        // LL-001: 정리는 모든 경로에서 돌아야 한다. 단, 그사이 `clear()` 가 돌았으면 로딩 플래그와
        // 진행 슬롯은 이미 새 세대의 것이라 건드리지 않는다(LL-003 — 슬롯은 내 세대일 때만 비운다).
        defer {
            if generation == started {
                isLoading = false
                inFlight = nil
            }
        }

        do {
            let dtos = try await authStore.withValidAccessToken { [api] token in
                try await api.records(accessToken: token)
            }
            guard generation == started else { return }
            records = try Self.mapped(dtos)
        } catch {
            // 이 Task 를 취소하는 것은 `clear()` 뿐이고, 그때는 세대도 바뀌어 있다. 취소는 오류 종류가
            // 아니라 상태로 판정한다(LL-001) — 가짜 "네트워크 오류"를 띄우지 않는다.
            guard generation == started, !Task.isCancelled else { return }
            loadError = AnalysisStore.mapped(error)
        }
    }

    /// 서버 항목 → `AnalysisRecord`. 미지 modality 항목은 건너뛴다.
    ///
    /// 받은 항목이 있는데 **하나도 남지 않으면 오류다**(예: 서버가 modality 를 소문자로 보내기 시작한 경우).
    /// 빈 목록으로 두면 "아직 분석 기록이 없습니다"라는 거짓 문장이 된다 — 오류 상태 + 재시도로 보낸다.
    static func mapped(_ dtos: [AnalysisRecordDTO]) throws -> [AnalysisRecord] {
        let records = dtos.compactMap { AnalysisRecord(server: $0) }
        let skipped = dtos.count - records.count
        if skipped > 0 {
            #if DEBUG
            let modalities = dtos.filter { AnalysisModalityCode(rawValue: $0.modality) == nil }.map { $0.modality }
            print("[Veritae][Records] 미지 modality 로 건너뛴 항목 \(skipped)/\(dtos.count)건 — \(modalities)")
            #endif
            if records.isEmpty {
                throw AuthAPIError.decoding(
                    DecodingError.dataCorrupted(
                        DecodingError.Context(codingPath: [], debugDescription: "records 항목 \(skipped)건이 전부 미지 modality 다")
                    )
                )
            }
        }
        return records
    }

    /// 로그아웃·계정 전환 시 호출한다. 진행 중인 불러오기의 결과도 버린다.
    func clear() {
        generation += 1
        inFlight?.task.cancel()
        inFlight = nil
        records = nil
        loadError = nil
        isLoading = false
    }
}
