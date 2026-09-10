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
    /// 링크 입력은 대응 API가 없어 비활성이다 — 안내만 띄운다.
    @State private var showLinkUnsupported = false
    /// 업로드 전 검증에서 걸린 사유. 서버 왕복 없이 즉시 안내한다.
    @State private var inputError: String?

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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: UploadFileFactory.importableContentTypes
        ) { result in
            if case .success(let url) = result {
                loadPickedFile(url)
            }
        }
        .alert("아직 지원하지 않습니다", isPresented: $showLinkUnsupported) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("링크 분석은 준비 중입니다. 지금은 사진 · 영상 · 파일의 AI 생성 여부만 확인할 수 있습니다.")
        }
        .alert("분석할 수 없습니다", isPresented: .init(
            get: { inputError != nil },
            set: { if !$0 { inputError = nil } }
        )) {
            Button("확인", role: .cancel) { inputError = nil }
        } message: {
            Text(inputError ?? "")
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

                    Text("사진 · 영상 · 파일의\nAI 생성 여부를 확인합니다")
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
                        // 링크는 준비 중이라 눌리긴 하되(안내 표시) 시각적으로 구분한다.
                        .opacity(kind == .link ? 0.45 : 1)
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
        // 링크는 대응 서버 엔드포인트가 없다. 입력을 받아 놓고 분석 단계에서 거절하는 대신
        // 선택 시점에 바로 알린다 — 사기 판정 엔진이 붙을 때 함께 열린다.
        case .link: showLinkUnsupported = true
        case .file: showFileImporter = true
        }
    }

    private func loadPickedMedia(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                inputError = "선택한 항목을 읽을 수 없습니다."
                return
            }

            let filename = item.supportedContentTypes.first?.preferredFilenameExtension
                .map { isVideo ? "video.\($0)" : "image.\($0)" }
                ?? (isVideo ? "video.mov" : "image.jpg")

            let file: UploadFile?
            if isVideo {
                file = UploadFileFactory.video(from: data, filename: filename)
            } else {
                // HEIC 촬영본을 JPEG로 재인코딩한다 — 하지 않으면 서버가 400으로 거절한다.
                file = await UploadFileFactory.image(from: data, filename: filename)
            }

            guard let file else {
                inputError = "이 파일은 분석할 수 없습니다."
                return
            }
            if let hint = UploadRule.submitBlockingHint(for: file) {
                // 업로드 전에 막는다 — 100MB 영상을 다 올린 뒤 거절당하는 것보다 낫다.
                inputError = hint
                return
            }

            // 미리보기는 사진만 — 영상 썸네일 추출은 이번 범위 밖이다.
            let preview = isVideo ? nil : UIImage(data: file.data)
            withAnimation(.smooth) {
                selectedInput = AnalysisInput(
                    kind: isVideo ? .video : .photo,
                    title: isVideo ? "선택한 영상" : "선택한 사진",
                    subtitle: isVideo ? "영상" : "사진",
                    previewImage: preview,
                    file: file
                )
            }
        }
    }

    private func loadPickedFile(_ url: URL) {
        Task {
            let file: UploadFile?
            do {
                file = try await UploadFileFactory.fromFile(url: url)
            } catch {
                inputError = "파일을 읽을 수 없습니다."
                return
            }
            guard let file else {
                inputError = "이미지 · 음성 · 영상 파일만 분석할 수 있습니다."
                return
            }
            if let hint = UploadRule.submitBlockingHint(for: file) {
                inputError = hint
                return
            }

            withAnimation(.smooth) {
                selectedInput = AnalysisInput(
                    kind: .file,
                    title: url.lastPathComponent,
                    subtitle: Self.subtitle(for: file.kind),
                    previewImage: file.kind == .image ? UIImage(data: file.data) : nil,
                    file: file
                )
            }
        }
    }

    private static func subtitle(for kind: UploadFile.Kind) -> String {
        switch kind {
        case .image: "파일 · 이미지"
        case .audio: "파일 · 음성"
        case .video: "파일 · 영상"
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
        .environment(AppState(authStore: AuthStore(api: MockAuthAPI(), tokenStore: InMemoryTokenStore()), analysisAPI: MockAnalysisAPI()))
}
#endif
