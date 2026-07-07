import SwiftUI

// MARK: - SC6 · 계정 (모달)

struct AccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

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
                if let record = appState.records.first(where: { $0.id == id }) {
                    DetailView(record: record)
                }
            }
        }
    }

    // MARK: 프로필

    private var profileCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint.opacity(0.8))

            Text(appState.userEmail ?? "알 수 없음")
                .font(.headline)

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

            if appState.records.isEmpty {
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
                    ForEach(appState.records) { record in
                        NavigationLink(value: record.id) {
                            HistoryRow(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - 기록 행

struct HistoryRow: View {
    let record: AnalysisRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: record.input.kind.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.input.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("AI \(record.aiProbability.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(record.aiLevel.color)

                Text(record.riskLevel.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(record.riskLevel.color)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .cardStyle()
    }
}

#Preview {
    AccountView()
        .environment(AppState())
}
