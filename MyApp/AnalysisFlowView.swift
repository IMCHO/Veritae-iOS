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
    /// 모달(분석 직후)에서는 X 로 닫고, 마이페이지에서 push 됐을 때는 시스템 뒤로가기를 쓴다.
    var showsCloseButton = true
    var onClose: () -> Void = {}

    @State private var playback: PlaybackController?
    @State private var waveform: [Float]?
    @State private var showOverlay = true

    /// 음성·영상은 서버가 구간 근거를 **제공하는** 모달리티다. 이미지(spai)만 제공하지 않는다.
    /// 이 구분이 없으면 "구간을 못 찾았다"를 "제공하지 않는다"로 잘못 말한다(실제로 그랬다).
    private var modelProvidesSegments: Bool { kind == .audio || kind == .video }

    private var kind: UploadFile.Kind? { record.input.file?.kind }
    private var hasTimeline: Bool { record.aiEvidence.contains { $0.timeRange != nil } }

    var body: some View {
        VStack(spacing: 16) {
            if showsCloseButton {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("닫기")
                }
            }

            ScrollView {
                VStack(spacing: 14) {
                    // 히어로 — 오버레이가 근거다. 원본 위에 히트맵, 토글·길게 눌러 비교.
                    MediaHeroView(record: record, playback: playback, waveform: waveform, showOverlay: $showOverlay)

                    if let playback, kind != .image {
                        Button {
                            playback.togglePlay()
                        } label: {
                            Label(playback.isPlaying ? "일시정지" : "재생", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 120, height: 34)
                        }
                        .buttonStyle(.glass)
                    }

                    // 게이지 — 숫자 하나가 아니라 구간 위의 바늘.
                    ScoreGaugeView(score: record.aiProbability, level: record.aiLevel, model: record.model)

                    // 사기 위험도는 서버에 판정 근거가 있을 때만. 있으면 **나란히** 둔다 — 평균 내지 않는다.
                    if let riskLevel = record.riskLevel {
                        VerdictCard(
                            title: "사기 위험도",
                            value: riskLevel.label,
                            caption: riskCaption(riskLevel),
                            color: riskLevel.color,
                            icon: "exclamationmark.shield"
                        )
                    }

                    // 시간 구간은 텍스트 카드가 아니라 타임라인 마커.
                    // 음성은 파형 자체가 타임라인이라 카드를 따로 두지 않는다. 영상은 히어로가
                    // 플레이어라 구간 마커를 아래에 둔다.
                    if hasTimeline, kind == .video {
                        EvidenceTimelineView(
                            segments: record.aiEvidence.filter { $0.timeRange != nil },
                            duration: playback?.duration ?? 0,
                            currentTime: playback?.currentTime ?? 0
                        ) { t in
                            playback?.seek(to: t)
                        }
                    }

                    // 범례 — "증거"가 아니라 "주목한 곳". 서버가 준 것만 설명한다.
                    legend

                    // 참고용 고지는 항상 보이게.
                    Label("AI 판독 결과는 참고용이며 확정적 증거가 아닙니다.", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            // 별도 "판독 정보" 화면은 두지 않는다 — 이 화면이 서버가 준 모든 것(점수·구간·히트맵)을
            // 이미 보여주고, 나머지(모델·파일명)는 게이지와 히어로에 있다.
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .task { await setUpPlayback() }
        .onDisappear { playback?.tearDown() }
    }

    @ViewBuilder
    private var legend: some View {
        let text: String? = {
            let hasHeatmap = record.evidenceImage != nil
            switch kind {
            case .video where hasHeatmap:
                return "붉게 표시된 영역은 모델이 판정에 가장 크게 반영한 부분입니다. 붉은 구간은 모델 출력에서 나온 값입니다."
            case .video where hasTimeline, .audio where hasTimeline:
                return "붉은 구간은 모델이 합성 가능성을 높게 본 부분입니다. 구간은 모델 출력에서 나온 값입니다."
            case .image where hasHeatmap:
                return "붉게 표시된 영역은 모델이 판정에 가장 크게 반영한 부분입니다."
            default:
                return nil
            }
        }()
        if let text {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [RiskLevel.high.color, RiskLevel.medium.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 10, height: 10)
                    .padding(.top, 4)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        } else if modelProvidesSegments {
            // 모델은 구간을 낼 수 있는데 이번엔 하나도 안 나온 경우 — "제공 안 함"과 다른 상태다.
            Text("이 파일에서는 의심 구간이 검출되지 않았습니다. 위 확률만 참고해 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .cardStyle()
        } else {
            Text("이 모델(\(record.model))은 영역·구간 표시를 제공하지 않습니다. 위 확률만 참고해 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .cardStyle()
        }
    }

    private func setUpPlayback() async {
        guard let file = record.input.file, file.kind != .image, playback == nil else { return }
        let ext = (file.filename as NSString).pathExtension.isEmpty
            ? (file.kind == .audio ? "m4a" : "mov")
            : (file.filename as NSString).pathExtension
        guard let controller = PlaybackController(data: file.data, fileExtension: ext) else { return }
        playback = controller
        if file.kind == .audio {
            // 선택 시점에 계산한 파형이 있으면 그대로 쓴다.
            if let precomputed = record.input.waveform {
                waveform = precomputed
                return
            }
            // 없으면 실제 샘플에서 계산한다.
            let url = URL.temporaryDirectory.appending(path: "veritae-wave-\(record.id.uuidString).\(ext)")
            try? file.data.write(to: url)
            waveform = await WaveformLoader.load(url: url)
            try? FileManager.default.removeItem(at: url)
        }
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
