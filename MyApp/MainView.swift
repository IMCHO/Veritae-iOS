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
    /// 업로드 전 검증에서 걸린 사유. 서버 왕복 없이 즉시 안내한다.
    @State private var inputError: String?
    /// 선택한 항목을 읽고 변환하는 중. 영상은 파일 복사 + 읽기 + 썸네일 추출까지 하므로
    /// 실제로 수 초가 걸린다 — 그동안 아무 표시가 없으면 "눌러도 반응이 없다"로 보인다.
    @State private var isPreparingInput = false

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
        if isPreparingInput {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text("선택한 항목을 준비하고 있습니다…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .cardStyle()
            .transition(.opacity)
        } else if let input = selectedInput {
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
                        VStack(spacing: 2) {
                            Image(systemName: kind.icon)
                                .font(.system(size: 20, weight: .medium))
                            Text(kind.title)
                                .font(.caption)
                            // 준비 중임을 글자로 밝힌다. 흐리기만 하면 "왜 안 되는지"를
                            // 눌러 봐야 알 수 있다.
                            //
                            // **지원되는 버튼도 이 줄을 빈 문자열로 차지한다.** 조건부로
                            // 넣고 빼면 내용 높이가 달라져서, 정사각형 변 길이가 버튼마다
                            // 달라지고 링크만 원이 커진다(실측).
                            Text(isUnsupported(kind) ? "준비 중" : " ")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        // 높이를 고정하면 폭이 남아 타원이 된다. 가로를 균등 분배한 뒤
                        // `aspectRatio(1, contentMode: .fit)` 로 정사각형을 만들어야
                        // 기기 폭과 무관하게 정확한 원이 된다.
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    // `.opacity` 만으로 흐리게 두면 `.glass` 버튼 스타일이 누를 때 자체
                    // 하이라이트를 줘서 **눌리는 순간 활성 버튼처럼 밝아졌다가 되돌아온다.**
                    // `.disabled` 는 그 터치 피드백까지 없애 상태가 흔들리지 않는다.
                    .disabled(isUnsupported(kind) || isPreparingInput)
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
        .disabled(selectedInput == nil || isPreparingInput)
    }

    // MARK: 액션

    /// 대응 서버 엔드포인트가 없어 아직 못 받는 입력. 링크는 사기 판정 엔진이 붙을 때 함께 열린다.
    private func isUnsupported(_ kind: SourceKind) -> Bool {
        kind == .link
    }

    private func select(_ kind: SourceKind) {
        switch kind {
        case .photo: showPhotoPicker = true
        case .video: showVideoPicker = true
        case .link: break   // `.disabled` 라 도달하지 않는다.
        case .file: showFileImporter = true
        }
    }

    private func loadPickedMedia(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            withAnimation(.smooth) { isPreparingInput = true }
            defer { withAnimation(.smooth) { isPreparingInput = false } }

            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }

            let file: UploadFile?
            var thumbnailData: Data?
            do {
                if isVideo {
                    // **영상에 `loadTransferable(type: Data.self)` 를 쓰면 안 된다.** 영상은 수백 MB
                    // 가 될 수 있어 메모리 `Data` 로 제공되지 않고 파일 URL 표현으로만 온다 —
                    // 그래서 `Data` 로 요청하면 `nil` 이 돌아와 "선택한 항목을 읽을 수 없습니다"
                    // 로 떨어졌다(사용자 보고 → 재현 확인). `PickedMovie` 가 파일로 받아 온다.
                    let result = try await UploadFileFactory.video(from: item)
                    file = result?.file
                    thumbnailData = result?.thumbnailData
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        inputError = Self.diagnosing(
                            "선택한 항목을 읽을 수 없습니다.",
                            detail: "loadTransferable(Data) == nil, types=\(item.supportedContentTypes.map(\.identifier))"
                        )
                        return
                    }
                    // HEIC 촬영본을 JPEG로 재인코딩한다 — 하지 않으면 서버가 400으로 거절한다.
                    file = await UploadFileFactory.image(from: data)
                }
            } catch let error as UploadFileError {
                inputError = error.message
                return
            } catch {
                inputError = Self.diagnosing("선택한 항목을 읽을 수 없습니다.", detail: "\(error)")
                return
            }

            guard let file else {
                inputError = Self.diagnosing(
                    "이 파일은 분석할 수 없습니다.",
                    detail: "변환 실패 (isVideo=\(isVideo), types=\(item.supportedContentTypes.map(\.identifier)))"
                )
                return
            }
            if let hint = UploadRule.submitBlockingHint(for: file) {
                // 업로드 전에 막는다 — 100MB 영상을 다 올린 뒤 거절당하는 것보다 낫다.
                inputError = Self.diagnosing(hint, detail: "contentType=\(file.contentType), bytes=\(file.data.count)")
                return
            }

            let preview = isVideo
                ? thumbnailData.flatMap(UIImage.init(data:))
                : UIImage(data: file.data)
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
            withAnimation(.smooth) { isPreparingInput = true }
            defer { withAnimation(.smooth) { isPreparingInput = false } }

            let picked: UploadFileFactory.PickedMediaResult?
            do {
                picked = try await UploadFileFactory.fromFile(url: url)
            } catch let error as UploadFileError {
                inputError = error.message
                return
            } catch {
                inputError = Self.diagnosing("파일을 읽을 수 없습니다.", detail: "\(error)")
                return
            }
            guard let picked else {
                inputError = Self.diagnosing("이미지 · 음성 · 영상 파일만 분석할 수 있습니다.", detail: "ext=\(url.pathExtension)")
                return
            }
            let file = picked.file
            if let hint = UploadRule.submitBlockingHint(for: file) {
                inputError = hint
                return
            }

            // 음성은 파형을 미리 계산한다 — 미리보기가 파일명 한 줄이면 무엇을 골랐는지 안 보인다.
            var waveform: [Float]?
            if file.kind == .audio {
                let tmp = URL.temporaryDirectory.appending(path: "veritae-wave-\(UUID().uuidString).\(url.pathExtension)")
                if (try? file.data.write(to: tmp)) != nil {
                    waveform = await WaveformLoader.load(url: tmp)
                    try? FileManager.default.removeItem(at: tmp)
                }
            }

            // 파일 앱에서 골랐어도 **내용이 이미지면 사진, 영상이면 영상**으로 다룬다 — 미리보기·결과
            // 화면이 PhotosPicker 경로와 완전히 같아진다. 분석 라우팅은 원래 `file.kind` 로 했다.
            let sourceKind: SourceKind = switch file.kind {
                case .image: .photo
                case .video: .video
                case .audio: .file
            }
            let preview: UIImage? = switch file.kind {
                case .image: UIImage(data: file.data)
                case .video: picked.thumbnailData.flatMap(UIImage.init(data:))
                case .audio: nil
            }
            withAnimation(.smooth) {
                selectedInput = AnalysisInput(
                    kind: sourceKind,
                    title: url.lastPathComponent,
                    subtitle: Self.subtitle(for: file.kind),
                    previewImage: preview,
                    file: file,
                    waveform: waveform
                )
            }
        }
    }

    /// DEBUG 에서만 실패 원인을 문구에 덧붙인다.
    ///
    /// 입력 거절 사유가 6갈래인데 사용자에게는 다 비슷하게 보여서, "안 된다"는 보고만으로는
    /// 어디서 막혔는지 좁힐 수 없었다(실제로 한 라운드를 이것 때문에 썼다). Release 문구는
    /// 그대로 두고 개발 빌드에서만 원인을 드러낸다.
    private static func diagnosing(_ message: String, detail: String) -> String {
        #if DEBUG
        return "\(message)\n\n[DEBUG] \(detail)"
        #else
        return message
        #endif
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
            } else if input.file?.kind == .audio {
                // 음성은 파일명 대신 실제 파형. 구간 강조는 결과 화면에서만(아직 근거가 없다).
                VStack(spacing: 10) {
                    WaveformView(samples: input.waveform, segments: [], duration: 0)
                        .frame(height: min(120, maxHeight - 60))
                        .clipShape(.rect(cornerRadius: 12))
                    Text(input.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .cardStyle()
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
