import Foundation
import WebKit
import EasyMarkdownCore

@MainActor final class LocalResourceHandler: NSObject, WKURLSchemeHandler {
    var root: URL?
    var remoteImages = false
    var onBudgetChange: (() -> Void)?
    private let owner: UUID
    private let observationID = UUID()
    private static let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "EasyMarkdown.ImagePreview"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    private final class Pending {
        let id = UUID()
        let operation = BlockOperation()
        let cancellation = ImageLoadCancellation()
        var clients: [String: ([String: Any]) -> Void] = [:]
    }
    private final class Resource {
        let id: UUID
        let source: String
        let image: PreviewImage
        var clients: Set<String>
        init(id: UUID, source: String, image: PreviewImage, clients: Set<String>) {
            self.id = id; self.source = source; self.image = image; self.clients = clients
        }
        var reply: [String: Any] {
            ["url": "document-resource://image/" + id.uuidString,
             "width": image.width, "height": image.height, "bytes": image.estimatedDecodedBytes]
        }
    }
    private var pending: [String: Pending] = [:]
    private var pendingClients: [String: String] = [:]
    private var resources: [UUID: Resource] = [:]
    private var sourceResources: [String: UUID] = [:]
    private var clients: [String: UUID] = [:]
    private var requests: [ObjectIdentifier: (resource: UUID, task: Task<Void, Never>)] = [:]
    var resourceCount: Int { resources.count }

    init(owner: UUID = UUID()) {
        self.owner = owner
        super.init()
        ImageResourceBudget.shared.observe(owner: observationID) { [weak self] in self?.onBudgetChange?() }
    }

    func requestImage(id: String, source: String, completion: @escaping ([String: Any]) -> Void) {
        releaseImage(id: id)
        guard source.utf8.count <= 2 * 1024 * 1024 else { completion(["error": "budget"]); return }
        if let resourceID = sourceResources[source], let resource = resources[resourceID] {
            resource.clients.insert(id)
            clients[id] = resourceID
            completion(resource.reply)
            return
        }
        if let load = pending[source] {
            load.clients[id] = completion
            pendingClients[id] = source
            return
        }
        let load = Pending()
        load.clients[id] = completion
        pending[source] = load
        pendingClients[id] = source
        let root = root, remoteImages = remoteImages, generation = load.id
        load.operation.addExecutionBlock { [weak self, weak operation = load.operation, cancellation = load.cancellation] in
            guard operation?.isCancelled == false else { return }
            let result = autoreleasepool { Result<PreviewImage, Error> {
                guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
                    throw URLError(.unsupportedURL)
                }
                switch scheme {
                case "file":
                    guard let root else { throw CocoaError(.fileReadNoPermission) }
                    return try PreviewImage.load(url, within: root, maximumBytes: 64 * 1024 * 1024)
                case "data":
                    let (data, mimeType) = try ImageDownload.dataURL(source)
                    return try PreviewImage.inspect(data, mimeType: mimeType)
                case "http", "https":
                    guard remoteImages else { throw CocoaError(.fileReadNoPermission) }
                    let (data, mimeType) = try ImageDownload.load(url, cancellation: cancellation)
                    return try PreviewImage.inspect(data, mimeType: mimeType)
                default: throw URLError(.unsupportedURL)
                }
            } }
            guard operation?.isCancelled == false else { return }
            let delivered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                defer { delivered.signal() }
                self?.complete(source: source, generation: generation, result: result)
            }
            // Bound completed-but-undelivered payloads even while AppKit is busy.
            delivered.wait()
        }
        Self.imageQueue.addOperation(load.operation)
    }

    private func complete(source: String, generation: UUID, result: Result<PreviewImage, Error>) {
        guard let load = pending[source], load.id == generation else { return }
        pending.removeValue(forKey: source)
        for id in load.clients.keys { pendingClients.removeValue(forKey: id) }
        let reply: [String: Any]
        switch result {
        case .success(let image):
            let resourceID = UUID()
            if ImageResourceBudget.shared.reserve(id: resourceID, owner: owner,
                decoded: image.estimatedDecodedBytes, encoded: image.data.count) {
                let resource = Resource(id: resourceID, source: source, image: image, clients: Set(load.clients.keys))
                resources[resourceID] = resource
                sourceResources[source] = resourceID
                for id in resource.clients { clients[id] = resourceID }
                reply = resource.reply
            } else { reply = ["error": "budget"] }
        case .failure(let error):
            reply = ["error": (error as? CocoaError)?.code == .fileReadTooLarge ? "budget" : "unavailable"]
        }
        for completion in load.clients.values { completion(reply) }
    }

    func releaseImage(id: String) {
        if let source = pendingClients.removeValue(forKey: id), let load = pending[source] {
            load.clients.removeValue(forKey: id)
            if load.clients.isEmpty {
                load.operation.cancel()
                load.cancellation.cancel()
                pending.removeValue(forKey: source)
            }
        }
        guard let resourceID = clients.removeValue(forKey: id), let resource = resources[resourceID] else { return }
        resource.clients.remove(id)
        guard resource.clients.isEmpty else { return }
        resources.removeValue(forKey: resourceID)
        sourceResources.removeValue(forKey: resource.source)
        for (key, request) in requests where request.resource == resourceID {
            request.task.cancel()
            requests.removeValue(forKey: key)
        }
        ImageResourceBudget.shared.release(resourceID)
    }

    func cancelAll() {
        for load in pending.values { load.operation.cancel(); load.cancellation.cancel() }
        pending.removeAll()
        pendingClients.removeAll()
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        for id in resources.keys { ImageResourceBudget.shared.release(id) }
        resources.removeAll()
        sourceResources.removeAll()
        clients.removeAll()
        ImageResourceBudget.shared.removeObserver(owner: observationID)
        onBudgetChange = nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "image",
              let resourceID = UUID(uuidString: url.lastPathComponent), let resource = resources[resourceID] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let task = Task { @MainActor [weak self] in
            defer { self?.requests.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            let data = resource.image.data
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": resource.image.mimeType, "Content-Length": String(data.count),
                "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"
            ])!
            urlSchemeTask.didReceive(response)
            var offset = 0
            repeat {
                guard !Task.isCancelled else { return }
                let end = min(data.count, offset + 256 * 1024)
                urlSchemeTask.didReceive(data.subdata(in: offset..<end))
                offset = end
                if offset < data.count { await Task.yield() }
            } while offset < data.count
            guard !Task.isCancelled else { return }
            urlSchemeTask.didFinish()
        }
        requests[id] = (resourceID, task)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.task.cancel()
    }
}
