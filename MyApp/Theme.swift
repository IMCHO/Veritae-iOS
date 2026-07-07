import SwiftUI
import UIKit

// MARK: - 공통 디자인 요소

/// 앱 전체에서 사용하는 배경. 콘텐츠 레이어는 심플하게 유지한다.
struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(uiColor: .systemBackground), Color.accentColor.opacity(0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// 콘텐츠 레이어용 심플 카드 배경 (Liquid Glass는 컨트롤에만 사용)
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardBackground())
    }
}

/// 앱 로고 마크
struct LogoMark: View {
    var size: CGFloat = 96

    var body: some View {
        Image(systemName: "checkmark.shield.fill")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .glassEffect(.regular, in: .rect(cornerRadius: size * 0.28))
    }
}
