import SwiftUI
import PhotosUI

// MARK: - SC2 · 메인 (분석 입력)

struct MainView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedInput: AnalysisInput?
    @State private var showAccount = false
    @State private var showAnalysis = false

    // 소스 선택 상태
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showVideoPicker = false
    @State private var showFileImporter = false
    @State private var showLinkInput = false
    @State private var linkText = ""

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 24) {
                header

                Spacer()

                previewArea

                Spacer()

                sourceButtons

                analyzeButton
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showAccount) {
            AccountView()
        }
        .fullScreenCover(isPresented: $showAnalysis) {
            if let selectedInput {
                AnalysisFlowView(input: selectedInput) {
                    self.selectedInput = nil
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .photosPicker(isPresented: $showVideoPicker, selection: $photoItem, matching: .videos)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                selectedInput = AnalysisInput(
                    kind: .file,
                    title: url.lastPathComponent,
                    subtitle: "파일",
                    previewImage: nil
                )
            }
        }
        .alert("링크 분석", isPresented: $showLinkInput) {
            TextField("https://...", text: $linkText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("확인") {
                guard !linkText.isEmpty else { return }
                selectedInput = AnalysisInput(
                    kind: .link,
                    title: linkText,
                    subtitle: "링크",
                    previewImage: nil
                )
                linkText = ""
            }
            Button("취소", role: .cancel) { linkText = "" }
        } message: {
            Text("분석할 링크 주소를 입력하세요.")
        }
        .onChange(of: photoItem) { _, newItem in
            loadPickedMedia(newItem)
        }
    }

    // MARK: 상단 헤더

    private var header: some View {
        HStack {
            Text("Veritae")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Spacer()

            Button {
                showAccount = true
            } label: {
                Image(systemName: "person")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("계정")
        }
        .padding(.top, 8)
    }

    // MARK: 선택된 콘텐츠 미리보기

    @ViewBuilder
    private var previewArea: some View {
        if let input = selectedInput {
            VStack(spacing: 16) {
                SourcePreview(input: input, maxHeight: 280)

                Button {
                    withAnimation(.smooth) {
                        selectedInput = nil
                        photoItem = nil
                    }
                } label: {
                    Label("선택 해제", systemImage: "xmark")
                        .font(.subheadline)
                }
                .buttonStyle(.glass)
            }
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        } else {
            VStack(spacing: 14) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text("무엇을 검증할까요?")
                        .font(.headline)

                    Text("사진, 영상, 링크, 파일의\nAI 생성 여부와 사기 위험도를 확인합니다")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                    .foregroundStyle(.quaternary)
            }
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    // MARK: 소스 선택 버튼

    private var sourceButtons: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 12) {
                ForEach(SourceKind.allCases) { kind in
                    Button {
                        select(kind)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: kind.icon)
                                .font(.system(size: 20, weight: .medium))
                            Text(kind.title)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: 분석 버튼

    private var analyzeButton: some View {
        Button {
            showAnalysis = true
        } label: {
            Label("분석하기", systemImage: "sparkles")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
        }
        .buttonStyle(.glassProminent)
        .disabled(selectedInput == nil)
    }

    // MARK: 액션

    private func select(_ kind: SourceKind) {
        switch kind {
        case .photo: showPhotoPicker = true
        case .video: showVideoPicker = true
        case .link: showLinkInput = true
        case .file: showFileImporter = true
        }
    }

    private func loadPickedMedia(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            var image: UIImage?
            if !isVideo, let data = try? await item.loadTransferable(type: Data.self) {
                image = UIImage(data: data)
            }
            withAnimation(.smooth) {
                selectedInput = AnalysisInput(
                    kind: isVideo ? .video : .photo,
                    title: isVideo ? "선택한 영상" : "선택한 사진",
                    subtitle: isVideo ? "영상" : "사진",
                    previewImage: image
                )
            }
        }
    }
}

// MARK: - 소스 미리보기 (메인/분석/결과 공용)

struct SourcePreview: View {
    var input: AnalysisInput
    var maxHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            if let image = input.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxHeight: maxHeight)
                    .clipShape(.rect(cornerRadius: 24))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: input.kind.icon)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)

                    Text(input.title)
                        .font(.subheadline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity)
                .frame(height: min(180, maxHeight))
                .cardStyle()
            }
        }
    }
}

#if DEBUG
// M8: `MockAuthAPI`/`InMemoryTokenStore`는 DEBUG 전용이라 프리뷰도 맞춰 감싼다
// (실측: 없이 했다가 Release 빌드가 "cannot find 'MockAuthAPI' in scope"로 실패했다).
#Preview {
    MainView()
        .environment(AppState(authStore: AuthStore(api: MockAuthAPI(), tokenStore: InMemoryTokenStore())))
}
#endif
