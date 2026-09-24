import SwiftUI

// MARK: - SC6 · 계정 (모달)

struct AccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// 기록 목록의 정본은 서버다(ADR-0017). 로컬에 쌓아 둔 것이 아니다.
    private var history: AnalysisHistoryStore { appState.history }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    profileCard

                    historySection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(AppBackground())
            .navigationTitle("계정")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AnalysisRecord.ID.self) { id in
                if let record = history.records?.first(where: { $0.id == id }) {
                    RecordDetailView(record: record)
                }
            }
        }
        // 시트를 열 때마다 불러온다 — 방금 끝난 분석도 서버가 완료 기록으로 돌려주므로 따로 끼워 넣지 않는다.
        .task { await history.load() }
    }

    // MARK: 프로필

    private var profileCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint.opacity(0.8))

            VStack(spacing: 4) {
                Text(appState.authStore.member?.nickname ?? "알 수 없음")
                    .font(.headline)

                if let email = appState.authStore.member?.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                dismiss()
                appState.signOut()
            } label: {
                Text("로그아웃")
                    .font(.subheadline)
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: 분석 기록

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("분석 기록")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 4)

            if let error = history.loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.orange)

                    Text(error.errorDescription ?? "분석 기록을 불러오지 못했습니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if error.isRetryable {
                        Button {
                            Task { await history.load() }
                        } label: {
                            Text("다시 시도")
                                .font(.subheadline)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 140)
                .cardStyle()
            } else if let records = history.records {
                if records.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)

                        Text("아직 분석 기록이 없습니다")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .cardStyle()
                } else {
                    VStack(spacing: 10) {
                        ForEach(records) { record in
                            NavigationLink(value: record.id) {
                                HistoryRow(record: record)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 서버가 최신 10건만 준다(페이지네이션 없음) — 오래된 기록이 "사라진" 것으로 보이지 않게 알린다.
                    Text("최근 완료된 분석 10건까지 표시됩니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()

                    Text("분석 기록을 불러오고 있습니다…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .cardStyle()
            }
        }
    }
}

// MARK: - 기록 행

/// 기록 상세. 분석 직후 화면(`AnalysisFlowView` 의 결과 단계)과 **똑같이 그린다** — 같은 배경,
/// 같은 `ResultView`, 같은 우상단 X 버튼. 사용자는 두 화면이 완전히 같기를 원한다.
///
/// 이전에는 배경 없이 `ResultView` 만 push 해서 시트의 흰 배경 위에 흰 카드가 묻혔고, 상단도
/// "판독 결과" 제목 + 시스템 뒤로 버튼이라 달랐다. 내비게이션 바는 숨기지 않고 비워 둔다 —
/// 분석 직후 화면도 `NavigationStack` 안의 빈 바를 가지므로, 숨기면 내용이 위로 올라가 어긋난다.
///
/// 남은 차이는 원본 미디어(원본 토글·파형·재생)뿐이다. 서버가 업로드 원본을 보관하지 않아
/// 기록에는 원본이 없다 — 서버에 보관을 요청해 둔 상태다(`api/server-request-2026-09-24-original-media.md`).
private struct RecordDetailView: View {
    let record: AnalysisRecord
    /// push 된 화면 안에서 읽어야 "뒤로(pop)" 가 된다. 바깥(AccountView)의 dismiss 는 시트를 닫는다.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground()
            ResultView(record: record) { dismiss() }
        }
        .navigationBarBackButtonHidden(true)
    }
}

struct HistoryRow: View {
    let record: AnalysisRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: record.modality.historyIcon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                // 서버 기록에는 파일명이 없다 — 무엇을 분석했는지(모달리티)로 제목을 단다.
                Text(record.input?.title ?? record.modality.historyTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(record.date?.formatted(date: .abbreviated, time: .shortened) ?? "날짜 알 수 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                // AI 판독이 없는 기록(얼굴 없는 영상 등)은 0% 로 보이면 "AI 아님"으로 읽힌다 — 따로 표시한다.
                if let probability = record.aiProbability, let aiLevel = record.aiLevel {
                    Text("AI \(probability.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(aiLevel.color)
                } else {
                    Text("AI 판독 없음")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                // 서버가 `scamDetection` 을 주지 않은 기록은 `nil` 이다(image/audio 는 "텍스트 없음", 영상은
                // 명세가 의미를 정하지 않았다) — 이유는 말하지 않고 모델명으로 대신한다.
                if let riskLevel = record.riskLevel {
                    Text("사기 위험 \(riskLevel.label)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(riskLevel.color)
                } else if let model = record.model {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .cardStyle()
    }
}

private extension UploadFile.Kind {
    var historyIcon: String {
        switch self {
        case .image: "photo"
        case .audio: "waveform"
        case .video: "video"
        }
    }

    var historyTitle: String {
        switch self {
        case .image: "이미지 분석"
        case .audio: "음성 분석"
        case .video: "영상 분석"
        }
    }
}

#if DEBUG
// M8: `#if DEBUG`로 감싸는 이유 — `#Preview` 본문은 Release 빌드에서도 타입체크되는데
// `MockAuthAPI`/`InMemoryTokenStore`는 의도적으로 DEBUG 전용이다(실측: 없이 했다가
// Release 빌드가 "cannot find 'MockAuthAPI' in scope"로 실패했다).
//
// 준비 코드를 `#Preview`의 트레일링 클로저 밖, 평범한 함수로 뺀 이유: 그 클로저는
// `@ViewBuilder`라 `let` 선언 + void를 반환하는 메서드 호출(`debugSetMember`) + View 표현식을
// 섞으면 컴파일러가 내부 오류("failed to produce diagnostic for expression")로 죽는다(실측).
@MainActor
private func makePreviewAppStateWithMember() -> AppState {
    let authStore = AuthStore(api: MockAuthAPI(), tokenStore: InMemoryTokenStore())
    authStore.debugSetMember(MemberDTO(id: "preview-id", email: "preview@veritae.app", nickname: "프리뷰"))
    return AppState(authStore: authStore, analysisAPI: MockAnalysisAPI())
}

#Preview {
    // M8: 프로필 카드가 빈 값("알 수 없음")으로 보이지 않도록 member가 이미 채워진
    // `AppState`를 주입한다.
    AccountView()
        .environment(makePreviewAppStateWithMember())
}
#endif
