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

                // 이미지(SPAI)는 근거 카드를 만들지 않아 항상 빈 배열이다 — 빈 섹션 제목만
                // 남기지 않고 대신 그 사실을 밝힌다.
                if record.aiEvidence.isEmpty {
                    Text("이 모델(\(record.model))은 구간별 근거를 제공하지 않습니다. 위 확률만 참고해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                } else {
                    EvidenceSection(title: "AI 판독 근거", items: record.aiEvidence)
                }

                // 사기 위험도 근거는 서버에 대응 엔드포인트가 없어 실서버 경로에서 항상 비어 있다.
                if !record.riskEvidence.isEmpty {
                    EvidenceSection(title: "위험도 분석", items: record.riskEvidence)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(AppBackground())
        .navigationTitle("상세 분석")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var badges: [(label: String, color: Color)] {
        var result: [(label: String, color: Color)] = [
            ("AI \(record.aiProbability.formatted(.percent.precision(.fractionLength(0))))", record.aiLevel.color),
        ]
        if let riskLevel = record.riskLevel {
            result.append(("위험도 \(riskLevel.label)", riskLevel.color))
        }
        result.append((record.model, .secondary))
        return result
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
                // `severity`가 없으면(서버가 심각도를 주지 않는 경우) 중립 색을 쓴다 —
                // 임의 색으로 심각도를 암시하지 않는다.
                let tint = item.severity?.color ?? .accentColor

                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: .circle)

                Text(item.title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if let severity = item.severity {
                    Text(severity.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(severity.color.opacity(0.14), in: .capsule)
                        .foregroundStyle(severity.color)
                }
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
