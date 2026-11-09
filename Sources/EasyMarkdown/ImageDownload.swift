import Foundation

final class ImageLoadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func attach(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancel = cancelled
        lock.unlock()
        if cancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

/// Runs on the bounded image worker queue. The delegate stops oversized streams
/// before accumulating the whole response, including chunked HTTP responses.
private final class BoundedImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBytes = 64 * 1024 * 1024
    private let finished = DispatchSemaphore(value: 0)
    private var data = Data()
    private var mimeType = "application/octet-stream"
    private var failure: Error?

    func run(_ url: URL, cancellation: ImageLoadCancellation,
             configuration suppliedConfiguration: URLSessionConfiguration? = nil) throws -> (Data, String) {
        guard Self.allowed(url) else { throw URLError(.unsupportedURL) }
        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        cancellation.attach(task)
        task.resume()
        guard finished.wait(timeout: .now() + 35) == .success else {
            session.invalidateAndCancel()
            throw URLError(.timedOut)
        }
        session.finishTasksAndInvalidate()
        if let failure { throw failure }
        return (data, mimeType)
    }

    private static func allowed(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allowed(url) else {
            failure = URLError(.unsupportedURL)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            failure = URLError(.badServerResponse)
        } else if response.expectedContentLength > Self.maximumBytes {
            failure = CocoaError(.fileReadTooLarge)
        }
        mimeType = response.mimeType ?? mimeType
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard chunk.count <= Self.maximumBytes - data.count else {
            failure = CocoaError(.fileReadTooLarge)
            dataTask.cancel()
            return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        failure = failure ?? error
        finished.signal()
    }
}

enum ImageDownload {
    static func load(_ url: URL, cancellation: ImageLoadCancellation,
                     configuration: URLSessionConfiguration? = nil) throws -> (Data, String) {
        try BoundedImageDownload().run(url, cancellation: cancellation, configuration: configuration)
    }

    static func dataURL(_ source: String) throws -> (Data, String) {
        guard source.utf8.count <= 2 * 1024 * 1024, source.prefix(5).lowercased() == "data:",
              let comma = source.firstIndex(of: ",") else {
            throw CocoaError(.fileReadTooLarge)
        }
        let metadata = source[source.index(source.startIndex, offsetBy: 5)..<comma]
        let parts = metadata.split(separator: ";")
        let mimeType = parts.first.map(String.init)?.lowercased() ?? ""
        guard mimeType.hasPrefix("image/") else { throw CocoaError(.fileReadCorruptFile) }
        let payload = source[source.index(after: comma)...]
        if parts.dropFirst().contains(where: { $0.lowercased() == "base64" }) {
            guard let data = Data(base64Encoded: String(payload)) else { throw CocoaError(.fileReadCorruptFile) }
            return (data, mimeType)
        }
        var bytes: [UInt8] = []
        let encoded = Array(payload.utf8)
        var index = 0
        while index < encoded.count {
            if encoded[index] == 37 {
                guard index + 2 < encoded.count,
                      let value = UInt8(String(decoding: encoded[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                bytes.append(value)
                index += 3
            } else {
                bytes.append(encoded[index])
                index += 1
            }
        }
        return (Data(bytes), mimeType)
    }
}
