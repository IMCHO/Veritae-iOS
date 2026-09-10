import Foundation

/// 실서버 `AnalysisAPI` 구현. multipart 업로드 3종 + job 조회.
///
/// `URLSession.upload(for:from:)`를 쓴다 — `data(for:)`에 `httpBody`를 실으면 본문 전체가
/// 메모리에 한 번 더 복사된다. 영상은 최대 100MB라 그 차이가 실제로 크다.
struct LiveAnalysisAPI: AnalysisAPI {
    let baseURL: URL
    let urlSession: URLSession

    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    nonisolated func analyzeImage(_ file: UploadFile, accessToken: String) async throws -> ImageDetectionDTO {
        let (data, response) = try await upload(file, path: "/api/v1/analysis/image", accessToken: accessToken)
        let dto = try HTTPTransport.decodeSuccess(ImageAnalysisResponseDTO.self, data: data, response: response)
        return dto.aiDetection
    }

    nonisolated func analyzeAudio(_ file: UploadFile, accessToken: String) async throws -> AudioDetectionDTO {
        let (data, response) = try await upload(file, path: "/api/v1/analysis/audio", accessToken: accessToken)
        let dto = try HTTPTransport.decodeSuccess(AudioAnalysisResponseDTO.self, data: data, response: response)
        return dto.aiDetection
    }

    nonisolated func submitVideo(_ file: UploadFile, accessToken: String) async throws -> String {
        let (data, response) = try await upload(file, path: "/api/v1/analysis/video", accessToken: accessToken)
        // 202 Accepted — `decodeSuccess`의 2xx 판정에 그대로 걸린다.
        let dto = try HTTPTransport.decodeSuccess(AnalysisJobAcceptedDTO.self, data: data, response: response)
        return dto.jobId
    }

    nonisolated func job(id: String, accessToken: String) async throws -> AnalysisJobDTO {
        // jobId는 서버가 준 값을 그대로 되돌려준다. 경로 세그먼트로 들어가므로 인코딩한다 —
        // `String`으로 받기로 한 이상(ADR-0012) UUID 형태를 가정할 수 없다.
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/analysis/jobs/\(encoded)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTPTransport.send(request, using: urlSession)
        return try HTTPTransport.decodeSuccess(AnalysisJobDTO.self, data: data, response: response)
    }

    // MARK: - 업로드

    /// 서버 계약은 세 엔드포인트 모두 form 필드 이름이 `file` 이다.
    private nonisolated func upload(
        _ file: UploadFile,
        path: String,
        accessToken: String
    ) async throws -> (Data, HTTPURLResponse) {
        var multipart = MultipartBody()
        multipart.appendFile(
            name: "file",
            filename: file.filename,
            contentType: file.contentType,
            data: file.data
        )

        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        // 응답의 `tokenType`을 신뢰하지 않고 항상 "Bearer " 리터럴로 조립한다(ADR-0012).
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await urlSession.upload(for: request, from: multipart.finalized())
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthAPIError.transport(URLError(.badServerResponse))
            }
            return (data, httpResponse)
        } catch let error as AuthAPIError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw AuthAPIError.transport(error)
        } catch {
            throw AuthAPIError.transport(URLError(.unknown))
        }
    }
}
