import SwiftUI

// MARK: - SC5 · 상세 분석 (판독 근거)

struct DetailView: View {
    let record: AnalysisRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // 요약
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(badges, id: \.label) { badge in
                            Text(badge.label)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(badge.color.opacity(0.14), in: .capsule)
                                .foregroundStyle(badge.color)
                        }
                    }

                    Text(record.summary)
                        .font(.callout)
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                EvidenceSection(title: "AI 판독 근거", items: record.aiEvidence)

                EvidenceSection(title: "위험도 분석", items: record.riskEvidence)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(AppBackground())
        .navigationTitle("상세 분석")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var badges: [(label: String, color: Color)] {
        [
            ("AI \(record.aiProbability.formatted(.percent.precision(.fractionLength(0))))", record.aiLevel.color),
            ("위험도 \(record.riskLevel.label)", record.riskLevel.color),
        ]
    }
}

// MARK: - 근거 섹션

struct EvidenceSection: View {
    var title: String
    var items: [EvidenceItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 4)

            VStack(spacing: 10) {
                ForEach(items) { item in
                    EvidenceRow(item: item)
                }
            }
        }
    }
}

struct EvidenceRow: View {
    let item: EvidenceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(item.severity.color)
                    .frame(width: 32, height: 32)
                    .background(item.severity.color.opacity(0.12), in: .circle)

                Text(item.title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(item.severity.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(item.severity.color.opacity(0.14), in: .capsule)
                    .foregroundStyle(item.severity.color)
            }

            // 본문 — 가독성을 위해 행간과 보조 색상 사용
            Text(item.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

#Preview {
    NavigationStack {
        DetailView(record: .sample)
    }
}
