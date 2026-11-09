#if DEBUG
import Foundation
import EasyMarkdownCore

private final class ImageFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/wait" { return }
        let oversized = url.path == "/oversized"
        let failed = url.path == "/error"
        let response = HTTPURLResponse(url: url, statusCode: failed ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": oversized ? "100000000" : "70"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !oversized && !failed {
            let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==")!
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum ImageDownloadCheck {
    static func run() async throws {
        func load(_ path: String, cancellation: ImageLoadCancellation = ImageLoadCancellation()) async throws -> (Data, String) {
            try await Task.detached {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ImageFixtureProtocol.self]
                return try ImageDownload.load(URL(string: "https://image-fixture.invalid" + path)!,
                    cancellation: cancellation, configuration: configuration)
            }.value
        }
        let (data, mimeType) = try await load("/valid")
        let image = try PreviewImage.inspect(data, mimeType: mimeType)
        guard image.width == 1, image.height == 1, image.estimatedDecodedBytes == 4 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for path in ["/oversized", "/error"] {
            do { _ = try await load(path); throw CocoaError(.coderInvalidValue) }
            catch let error as CocoaError where error.code == .coderInvalidValue { throw error }
            catch { /* Expected refusal before decoding. */ }
        }
        let cancellation = ImageLoadCancellation()
        let pending = Task { try await load("/wait", cancellation: cancellation) }
        try await Task.sleep(for: .milliseconds(100))
        cancellation.cancel()
        do { _ = try await pending.value; throw CocoaError(.coderInvalidValue) }
        catch let error as CocoaError where error.code == .coderInvalidValue { throw error }
        catch { /* In-flight network requests must finish cancellation. */ }
    }
}
#endif
