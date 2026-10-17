import Foundation

final class LooiReleaseRedirects: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int
    let progress: (@MainActor @Sendable (Double) -> Void)?
    init(limit: Int = 3146752, progress: (@MainActor @Sendable (Double) -> Void)? = nil) { self.limit = limit; self.progress = progress }
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var downloaded: Data?
    private var readError: Error?
    func download(_ url: URL, session: URLSession) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }
    private func report(_ sent: Int64, _ total: Int64) {
        guard total > 0, let progress else { return }
        let value = min(1, max(0, Double(sent) / Double(total)))
        Task { @MainActor in progress(value) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel(); return }
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? limit + 1
            guard size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
            downloaded = try Data(contentsOf: location)
        } catch { readError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error = error ?? readError { continuation.resume(throwing: error) }
        else if let downloaded, let response = task.response { continuation.resume(returning: (downloaded, response)) }
        else { continuation.resume(throwing: URLError(.badServerResponse)) }
        downloaded = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { report(totalBytesSent, totalBytesExpectedToSend) }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let trusted = request.url?.scheme == "https" && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(request.url?.host ?? "")
        completionHandler(trusted ? request : nil)
    }
}
