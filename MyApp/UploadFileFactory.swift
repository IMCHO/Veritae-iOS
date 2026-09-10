import UIKit
import UniformTypeIdentifiers

/// 선택된 미디어(PhotosPicker / 파일 선택)를 서버가 받는 형식의 `UploadFile`로 맞춘다.
///
/// **Content-Type을 확장자에서 결정한다.** `UTType.preferredMIMEType`을 쓰지 않는 이유는
/// 서버 `validate()`가 **정확한 문자열 집합**과 대조하기 때문이다 — 시스템이 주는 값이
/// 그 집합과 한 글자라도 다르면(예: m4a에 `audio/m4a`) 400 `INVALID_AUDIO_FILE`이 된다.
/// 서버가 허용하는 값만 직접 매핑해 그 위험을 없앤다.
enum UploadFileFactory {

    /// 서버가 재인코딩 없이 받는 이미지 형식.
    private nonisolated static let passthroughImageTypes: [String: String] = [
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "webp": "image/webp",
    ]

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

    /// 사진용. 서버가 그대로 받는 형식이면 원본 바이트를 유지하고, 그 외에는 **JPEG로 재인코딩한다.**
    ///
    /// 재인코딩이 필수인 이유: iPhone 기본 촬영 포맷은 **HEIC**인데 서버는 jpeg/png/webp만
    /// 받는다. 변환하지 않으면 사진 촬영본 대부분이 400 `INVALID_IMAGE_FILE`로 튕긴다.
    ///
    /// `nonisolated`는 성능 요구다 — 디코딩·재인코딩은 수 MB 이미지에서 수백 ms가 걸린다.
    /// 무표기면 이 모듈의 기본 격리(MainActor) 때문에 그 시간 동안 화면이 멎는다(LL-002).
    nonisolated static func image(from data: Data, filename: String) async -> UploadFile? {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let contentType = passthroughImageTypes[ext] {
            return UploadFile(kind: .image, filename: filename, contentType: contentType, data: data)
        }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
            return nil
        }
        let base = (filename as NSString).deletingPathExtension
        return UploadFile(
            kind: .image,
            filename: base.isEmpty ? "image.jpg" : "\(base).jpg",
            contentType: "image/jpeg",
            data: jpeg
        )
    }

    /// 파일 선택에서 온 URL을 읽어 종류를 판별한다.
    ///
    /// 반환이 `nil`이면 서버가 받지 않는 형식이다 — 호출부가 업로드 전에 안내해야 한다.
    /// 이미지는 여기서도 필요하면 JPEG로 재인코딩한다(파일 앱에서 HEIC를 고를 수 있다).
    nonisolated static func fromFile(url: URL) async throws -> UploadFile? {
        let data = try Data(contentsOf: url)
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        if let contentType = audioTypes[ext] {
            return UploadFile(kind: .audio, filename: filename, contentType: contentType, data: data)
        }
        if let contentType = videoTypes[ext] {
            return UploadFile(kind: .video, filename: filename, contentType: contentType, data: data)
        }
        // 확장자로 이미지라고 단정할 수 없는 경우까지 UTType으로 한 번 더 본다 —
        // 파일 앱에서 확장자 없는 항목을 고를 수 있다.
        let isImage = passthroughImageTypes[ext] != nil
            || (UTType(filenameExtension: ext)?.conforms(to: .image) ?? false)
            || UIImage(data: data) != nil
        guard isImage else { return nil }
        return await image(from: data, filename: filename)
    }

    /// PhotosPicker 영상용. 확장자를 못 읽으면 mov로 본다 — iOS 카메라 기본 컨테이너다.
    nonisolated static func video(from data: Data, filename: String) -> UploadFile {
        let ext = (filename as NSString).pathExtension.lowercased()
        return UploadFile(
            kind: .video,
            filename: filename,
            contentType: videoTypes[ext] ?? "video/quicktime",
            data: data
        )
    }

    /// 파일 선택 다이얼로그에 노출할 형식. `.item`(전부)으로 두면 서버가 못 받는 파일을
    /// 고르게 해놓고 나중에 거절하는 셈이 된다.
    nonisolated static var importableContentTypes: [UTType] {
        [.jpeg, .png, .webP, .heic, .heif, .mpeg4Movie, .quickTimeMovie, .avi, .wav, .mp3, .mpeg4Audio]
    }
}
