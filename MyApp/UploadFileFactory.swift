import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 업로드 대상 준비 중 사용자에게 알려야 하는 실패.
enum UploadFileError: Error {
    case tooLarge(String)
    case unreadable(String)

    var message: String {
        switch self {
        case .tooLarge(let m), .unreadable(let m): m
        }
    }
}

/// PhotosPicker 영상 전용 `Transferable`.
///
/// **영상은 `Data` 로 받을 수 없다.** `loadTransferable(type: Data.self)` 는 영상 항목에
/// `nil` 을 돌려준다 — 영상은 수백 MB 가 될 수 있어 시스템이 메모리 표현을 제공하지 않고
/// 파일 URL 표현만 준다. 처음엔 사진과 같은 경로로 짰다가 영상 선택이 전부
/// "선택한 항목을 읽을 수 없습니다" 로 떨어졌다(사용자 보고 → 재현 확인).
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            // `received.file` 은 시스템이 내준 임시 위치라 이 클로저가 끝나면 사라진다.
            // 우리 임시 디렉터리로 복사해 수명을 우리가 통제한다.
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = URL.temporaryDirectory
                .appending(path: "veritae-upload-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

/// 선택된 미디어(PhotosPicker / 파일 선택)를 서버가 받는 형식의 `UploadFile`로 맞춘다.
///
/// **Content-Type 을 확장자가 아니라 실제 바이트로 판정한다.** 서버 `validate()` 가 정확한
/// 문자열 집합과 대조하므로, 확장자만 믿으면 `.jpg` 로 저장된 HEIC 같은 경우에
/// `image/jpeg` 라고 거짓 신고해 서버에서 400 이 난다.
enum UploadFileFactory {

    private nonisolated static let audioTypes: [String: String] = [
        "wav": "audio/wav",
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
    ]

    private nonisolated static let videoTypes: [String: String] = [
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "avi": "video/x-msvideo",
    ]

    // MARK: - 이미지

    /// 서버가 그대로 받는 형식(jpeg/png/webp)이면 원본 바이트를 유지하고, 그 외에는
    /// **JPEG 로 재인코딩한다.**
    ///
    /// 재인코딩이 필수인 이유: iPhone 기본 촬영 포맷은 **HEIC** 인데 서버는 jpeg/png/webp 만
    /// 받는다. 변환하지 않으면 사진 촬영본 대부분이 400 `INVALID_IMAGE_FILE` 로 튕긴다.
    ///
    /// `nonisolated` 는 성능 요구다 — 디코딩·재인코딩은 수 MB 이미지에서 수백 ms 가 걸린다.
    /// 무표기면 이 모듈의 기본 격리(MainActor) 때문에 그 시간 동안 화면이 멎는다(LL-002).
    nonisolated static func image(from data: Data, filename: String? = nil) async -> UploadFile? {
        if let sniffed = ImageByteFormat(data: data) {
            return UploadFile(
                kind: .image,
                filename: filename ?? "image.\(sniffed.fileExtension)",
                contentType: sniffed.contentType,
                data: data
            )
        }
        // 서버가 받지 않는 형식(HEIC/HEIF/GIF/TIFF…)이거나 판별 불가 — JPEG 로 통일한다.
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            return nil
        }
        return UploadFile(kind: .image, filename: "image.jpg", contentType: "image/jpeg", data: jpeg)
    }

    // MARK: - 영상

    /// 영상 업로드 대상 + 미리보기 썸네일.
    ///
    /// 썸네일을 여기서 만드는 이유: 원본 파일 URL 이 있어야 프레임을 뽑을 수 있는데, 그 임시
    /// 파일은 이 함수가 끝나면서 지워진다. 밖으로 URL 을 내보내면 수명 관리가 호출부로 새어
    /// 나가므로, 필요한 것(바이트 + 썸네일)만 만들어 돌려준다.
    nonisolated struct PickedVideoResult: Sendable {
        let file: UploadFile
        /// JPEG 바이트. 실패하면 `nil` — 썸네일이 없다고 분석을 막지는 않는다.
        let thumbnailData: Data?
    }

    /// PhotosPicker 영상 항목을 파일 URL 로 받아 `UploadFile` + 썸네일로 만든다.
    ///
    /// **용량을 먼저 파일 속성으로 확인하고, 상한을 넘으면 읽지 않고 거절한다.** 100MB 초과
    /// 영상을 일단 메모리로 읽어 들이면 그 자체로 압박이 크다.
    nonisolated static func video(from item: PhotosPickerItem) async throws -> PickedVideoResult? {
        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }

        let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= UploadRule.videoMaxBytes else {
            throw UploadFileError.tooLarge(
                "영상 파일은 100MB까지 분석할 수 있습니다. 이 영상은 \(byteText(size))입니다 — 더 짧은 영상으로 시도해 주세요."
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: movie.url, options: .mappedIfSafe)
        } catch {
            throw UploadFileError.unreadable("선택한 영상을 읽을 수 없습니다.")
        }

        let ext = movie.url.pathExtension.lowercased()
        let file = UploadFile(
            kind: .video,
            filename: movie.url.lastPathComponent,
            // 확장자를 못 읽으면 mov 로 본다 — iOS 카메라 기본 컨테이너다.
            contentType: videoTypes[ext] ?? "video/quicktime",
            data: data
        )
        return PickedVideoResult(file: file, thumbnailData: await thumbnail(for: movie.url))
    }

    /// 영상 첫 부분에서 한 프레임을 뽑아 JPEG 로 만든다.
    ///
    /// - `appliesPreferredTrackTransform` 이 없으면 세로로 찍은 영상이 눕는다.
    /// - 정확히 0초를 요구하면 키프레임이 없는 영상에서 실패하므로 앞쪽 구간에서 허용 오차를 준다.
    /// - 실패해도 `nil` 만 돌려준다 — 썸네일 때문에 분석을 막지 않는다.
    private nonisolated static func thumbnail(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.8)
        } catch {
            return nil
        }
    }

    // MARK: - 파일 선택

    /// 파일 선택에서 온 URL 을 읽어 종류를 판별한다. 반환이 `nil` 이면 서버가 받지 않는 형식이다.
    ///
    /// **security-scoped 접근을 반드시 열어야 한다.** 이 앱은 `ENABLE_APP_SANDBOX = YES` +
    /// `ENABLE_USER_SELECTED_FILES = readonly` 라서, `fileImporter` 가 준 URL 을 그냥
    /// `Data(contentsOf:)` 하면 권한 오류로 실패한다.
    nonisolated static func fromFile(url: URL) async throws -> UploadFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // 읽기 전에 용량으로 거절한다 — 영상은 100MB, 음성은 25MB.
        if videoTypes[ext] != nil, size > UploadRule.videoMaxBytes {
            throw UploadFileError.tooLarge("영상 파일은 100MB까지 분석할 수 있습니다. 이 파일은 \(byteText(size))입니다.")
        }
        if audioTypes[ext] != nil, size > UploadRule.audioMaxBytes {
            throw UploadFileError.tooLarge("음성 파일은 25MB까지 분석할 수 있습니다. 이 파일은 \(byteText(size))입니다.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw UploadFileError.unreadable("파일을 읽을 수 없습니다. 다른 위치의 파일로 시도해 주세요.")
        }

        if let contentType = audioTypes[ext] {
            return UploadFile(kind: .audio, filename: url.lastPathComponent, contentType: contentType, data: data)
        }
        if let contentType = videoTypes[ext] {
            return UploadFile(kind: .video, filename: url.lastPathComponent, contentType: contentType, data: data)
        }
        // 이미지 여부는 바이트로 판정한다 — 확장자가 없거나 틀린 파일도 파일 앱에서 고를 수 있다.
        guard ImageByteFormat(data: data) != nil || UIImage(data: data) != nil else {
            return nil
        }
        return await image(from: data, filename: url.lastPathComponent)
    }

    /// 파일 선택 다이얼로그에 노출할 형식. `.item`(전부)으로 두면 서버가 못 받는 파일을
    /// 고르게 해놓고 나중에 거절하는 셈이 된다.
    nonisolated static var importableContentTypes: [UTType] {
        [.jpeg, .png, .webP, .heic, .heif, .mpeg4Movie, .quickTimeMovie, .avi, .wav, .mp3, .mpeg4Audio]
    }

    private nonisolated static func byteText(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0fMB", mb.rounded())
    }
}

/// 서버가 **그대로 받는** 이미지 형식만 매직 바이트로 식별한다.
///
/// 확장자를 신뢰하지 않는 이유: `.jpg` 로 저장된 HEIC 파일을 `image/jpeg` 로 신고하면 서버
/// `validate()` 는 Content-Type 만 보고 통과시키지만 탐지 서버가 실제 바이트를 열지 못한다.
/// 반대로 확장자가 없는 PNG 를 놓치면 불필요하게 재인코딩한다.
nonisolated enum ImageByteFormat {
    case jpeg
    case png
    case webp

    init?(data: Data) {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if data.count >= 12,
                  data.starts(with: [0x52, 0x49, 0x46, 0x46]),                    // "RIFF"
                  Array(data[data.startIndex + 8..<data.startIndex + 12]) == [0x57, 0x45, 0x42, 0x50] {  // "WEBP"
            self = .webp
        } else {
            return nil
        }
    }

    var contentType: String {
        switch self {
        case .jpeg: "image/jpeg"
        case .png: "image/png"
        case .webp: "image/webp"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .webp: "webp"
        }
    }
}
