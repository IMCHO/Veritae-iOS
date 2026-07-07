import SwiftUI

// MARK: - SC3/SC4 · 분석 모달 (분석 중 → 결과 → 상세 push)

struct AnalysisFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let input: AnalysisInput
    var onFinish: () -> Void

    @State private var record: AnalysisRecord?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                if let record {
                    ResultView(record: record) {
                        onFinish()
                        dismiss()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    AnalyzingView(input: input)
                        .transition(.opacity)
                }
            }
            .navigationDestination(for: AnalysisRecord.ID.self) { _ in
                if let record {
                    DetailView(record: record)
                }
            }
        }
        .task {
            let result = await AnalysisEngine.analyze(input)
            appState.records.insert(result, at: 0)
            withAnimation(.smooth(duration: 0.5)) {
                record = result
            }
        }
        .interactiveDismissDisabled(record == nil)
    }
}

// MARK: - SC3 · 분석 중

struct AnalyzingView: View {
    let input: AnalysisInput

    @State private var phaseIndex = 0

    private let phases = [
        "콘텐츠 확인 중…",
        "AI 생성 패턴 분석 중…",
        "위험 신호 대조 중…",
        "결과 정리 중…",
    ]

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
                Text(phases[phaseIndex])
                    .font(.headline)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: phaseIndex)

                Text("잠시만 기다려 주세요")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .task {
            // 진행 단계 문구를 주기적으로 교체
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.9))
                if phaseIndex < phases.count - 1 {
                    phaseIndex += 1
                }
            }
        }
    }

    @State private var rotation: Double = 0
    @State private var pulse = false
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

                        VerdictCard(
                            title: "사기 위험도",
                            value: record.riskLevel.label,
                            caption: riskCaption,
                            color: record.riskLevel.color,
                            icon: "exclamationmark.shield"
                        )
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

    private var riskCaption: String {
        switch record.riskLevel {
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

#Preview("분석 중") {
    ZStack {
        AppBackground()
        AnalyzingView(input: AnalysisInput(kind: .link, title: "https://example.com/photo.jpg", subtitle: "링크", previewImage: nil))
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
    /// 프리뷰용 샘플 데이터
    static var sample: AnalysisRecord {
        AnalysisRecord(
            date: .now,
            input: AnalysisInput(kind: .link, title: "https://example.com/photo.jpg", subtitle: "링크", previewImage: nil),
            aiProbability: 0.82,
            riskLevel: .medium,
            summary: "이 콘텐츠는 AI로 생성되었을 가능성이 높습니다. 공유하거나 신뢰하기 전에 출처를 확인하세요.",
            aiEvidence: [
                EvidenceItem(icon: "waveform.path.ecg", title: "주파수 패턴 분석", detail: "고주파 영역에서 생성 모델 특유의 규칙적인 노이즈 패턴이 감지되었습니다.", severity: .high),
                EvidenceItem(icon: "eye", title: "시각적 일관성 검사", detail: "조명 방향과 그림자의 물리적 일관성 오차가 허용 범위 내에 있습니다.", severity: .low),
            ],
            riskEvidence: [
                EvidenceItem(icon: "exclamationmark.bubble", title: "유포 이력", detail: "유사 콘텐츠의 사기 신고 이력이 확인되지 않았습니다.", severity: .medium),
            ]
        )
    }
}
