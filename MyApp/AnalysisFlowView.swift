import SwiftUI

// MARK: - SC3/SC4 · 분석 모달 (분석 중 → 결과 → 상세 push)

struct AnalysisFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let input: AnalysisInput
    var onFinish: () -> Void

    private var store: AnalysisStore { appState.analysisStore }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                switch store.phase {
                case .finished(let record):
                    ResultView(record: record) {
                        onFinish()
                        dismiss()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))

                case .failed(let error):
                    FailureView(
                        error: error,
                        onRetry: error.isRetryable ? { Task { await run() } } : nil,
                        onClose: {
                            onFinish()
                            dismiss()
                        }
                    )
                    .transition(.opacity)

                case .running(let stage):
                    AnalyzingView(input: input, stage: stage)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.4), value: store.isFinished)
            .navigationDestination(for: AnalysisRecord.ID.self) { _ in
                if case .finished(let record) = store.phase {
                    DetailView(record: record)
                }
            }
        }
        .task { await run() }
    }

    /// 진행 중이던 영상 job이 있으면 이어서 폴링하고, 없으면 새로 분석한다.
    /// 모달을 닫았다 다시 열었을 때 같은 작업을 두 번 접수하지 않기 위한 분기다.
    private func run() async {
        if store.pendingVideoJob != nil {
            await store.resumePendingVideoJobIfNeeded()
        } else {
            await store.analyze(input)
        }
        if case .finished(let record) = store.phase {
            appState.records.insert(record, at: 0)
        }
    }
}

// MARK: - SC3 · 분석 중

struct AnalyzingView: View {
    let input: AnalysisInput
    /// 서버가 실제로 어디까지 왔는지. 예전에는 문구 4개를 0.9초마다 돌렸는데, 그건 진행과
    /// 무관한 연출이라 영상처럼 수 분 걸리는 작업에서 "결과 정리 중"에 멎어 있었다.
    let stage: AnalysisStore.Stage

    var body: some View {
        VStack(spacing: 48) {
            Spacer()

            ZStack {
                // 회전하는 그라데이션 링
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [.accentColor.opacity(0), .accentColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 260, height: 260)
                    .rotationEffect(.degrees(rotation))

                // 은은하게 맥동하는 보조 링
                Circle()
                    .stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
                    .frame(width: 292, height: 292)
                    .scaleEffect(pulse ? 1.04 : 0.98)
                    .opacity(pulse ? 0.4 : 1)

                SourcePreview(input: input, maxHeight: 200)
                    .frame(width: 200)
                    .clipShape(.rect(cornerRadius: 20))
            }

            VStack(spacing: 10) {
                Text(stage.label)
                    .font(.headline)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: stage)
                    .multilineTextAlignment(.center)

                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    /// 영상은 수십 초~수 분이 걸릴 수 있어 기다림의 성격이 다르다 — 화면을 닫아도 된다는
    /// 사실을 알려 준다(작업은 서버에서 계속된다).
    private var caption: String {
        switch stage {
        case .queued, .processing:
            "시간이 걸릴 수 있습니다.\n화면을 닫아도 분석은 계속됩니다."
        case .preparing, .uploading, .analyzing:
            "잠시만 기다려 주세요"
        }
    }

    @State private var rotation: Double = 0
    @State private var pulse = false
}

// MARK: - 분석 실패

struct FailureView: View {
    let error: AnalysisError
    /// `nil`이면 재시도 버튼을 감춘다 — 파일 자체가 문제인 경우 같은 파일로 다시 시도해도
    /// 결과가 같아서, 버튼을 두면 사용자를 헛돌게 만든다.
    var onRetry: (() -> Void)?
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.orange)

            Text(error.errorDescription ?? "분석에 실패했습니다.")
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            VStack(spacing: 10) {
                if let onRetry {
                    Button(action: onRetry) {
                        Text("다시 시도")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.glassProminent)
                }

                Button(action: onClose) {
                    Text("닫기")
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }
}

// MARK: - SC4 · 분석 결과

struct ResultView: View {
    let record: AnalysisRecord
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // 닫기
            HStack {
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("닫기")
            }

            ScrollView {
                VStack(spacing: 20) {
                    SourcePreview(input: record.input, maxHeight: 240)

                    // 판정 카드
                    VStack(spacing: 12) {
                        VerdictCard(
                            title: "AI 생성 가능성",
                            value: record.aiProbability.formatted(.percent.precision(.fractionLength(0))),
                            caption: record.aiLevel.label,
                            color: record.aiLevel.color,
                            icon: "cpu"
                        )

                        // 사기 위험도는 서버에 판정 근거가 있을 때만 보여준다. 없으면 카드를
                        // 감춘다 — 근거 없는 위험도를 노출하는 것이 사기예방 앱에서 가장 나쁘다.
                        if let riskLevel = record.riskLevel {
                            VerdictCard(
                                title: "사기 위험도",
                                value: riskLevel.label,
                                caption: riskCaption(riskLevel),
                                color: riskLevel.color,
                                icon: "exclamationmark.shield"
                            )
                        }
                    }

                    // 영상 히트맵 — best-effort라 없을 수 있다.
                    if let data = record.evidenceImage, let image = UIImage(data: data) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("판독 근거 히트맵")
                                .font(.subheadline.weight(.semibold))
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(.rect(cornerRadius: 12))
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            NavigationLink(value: record.id) {
                Label("상세 분석 보기", systemImage: "doc.text.magnifyingglass")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private func riskCaption(_ level: RiskLevel) -> String {
        switch level {
        case .low: "특이 신호 없음"
        case .medium: "주의가 필요합니다"
        case .high: "신뢰하지 마세요"
        }
    }
}

/// 결과 판정 카드 — 크고 심플하게
struct VerdictCard: View {
    var title: String
    var value: String
    var caption: String
    var color: Color
    var icon: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 52, height: 52)
                .background(color.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }

            Spacer()

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }
}

extension AnalysisStore {
    /// `Phase`는 `Equatable`이 아니라 애니메이션 트리거로 쓸 수 없어, 전환 여부만 뽑아 쓴다.
    var isFinished: Bool {
        if case .running = phase { return false }
        return true
    }
}

#Preview("분석 중") {
    ZStack {
        AppBackground()
        AnalyzingView(
            input: AnalysisInput(kind: .photo, title: "IMG_3958.jpg", subtitle: "사진", previewImage: nil),
            stage: .analyzing
        )
    }
}

#Preview("실패") {
    ZStack {
        AppBackground()
        FailureView(error: .detectionServiceUnavailable, onRetry: {}, onClose: {})
    }
}

#Preview("결과") {
    NavigationStack {
        ZStack {
            AppBackground()
            ResultView(record: .sample) {}
        }
    }
}

extension AnalysisRecord {
    /// 프리뷰용 샘플. 실서버 경로를 반영해 `riskLevel`은 `nil`, 근거는 서버 `Evidence`에서
    /// 오는 형태(severity 없음)로 둔다.
    static var sample: AnalysisRecord {
        AnalysisRecord(
            date: .now,
            input: AnalysisInput(kind: .video, title: "clip.mp4", subtitle: "영상", previewImage: nil),
            aiProbability: 0.82,
            summary: "AI로 생성되었을 가능성이 높습니다. 공유하거나 신뢰하기 전에 출처를 확인해 주세요.",
            aiEvidence: [
                EvidenceItem(
                    icon: "waveform.path.ecg",
                    title: "얼굴 경계 불일치",
                    detail: "1.0초~2.5초 구간에서 얼굴 윤곽과 배경의 경계가 프레임마다 흔들림\n구간: 1.0초~2.5초",
                    severity: nil
                ),
            ],
            model: "dfdc",
            evidenceImage: nil,
            riskLevel: nil,
            riskEvidence: []
        )
    }
}
