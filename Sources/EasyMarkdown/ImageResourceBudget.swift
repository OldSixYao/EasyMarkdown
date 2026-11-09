import Foundation

/// Metadata estimates bound admitted image resources, not WebKit's exact heap.
@MainActor final class ImageResourceBudget {
    static let shared = ImageResourceBudget()
    struct Limits {
        var documentDecoded = 128 * 1024 * 1024
        var totalDecoded = 256 * 1024 * 1024
        var documentEncoded = 64 * 1024 * 1024
        var totalEncoded = 128 * 1024 * 1024
        var documentCount = 32
        var totalCount = 64
    }
    private struct Charge { let owner: UUID; let decoded: Int; let encoded: Int }
    private let limits: Limits
    private var charges: [UUID: Charge] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var notificationPending = false
    private(set) var decodedBytes = 0
    private(set) var encodedBytes = 0
    var count: Int { charges.count }

    init(limits: Limits = Limits()) { self.limits = limits }

    func observe(owner: UUID, _ callback: @escaping () -> Void) { observers[owner] = callback }
    func removeObserver(owner: UUID) { observers.removeValue(forKey: owner) }

    func reserve(id: UUID, owner: UUID, decoded: Int, encoded: Int) -> Bool {
        guard charges[id] == nil, decoded >= 0, encoded >= 0 else { return false }
        let own = charges.values.filter { $0.owner == owner }
        guard charges.count < limits.totalCount, own.count < limits.documentCount,
              decoded <= limits.totalDecoded - decodedBytes,
              encoded <= limits.totalEncoded - encodedBytes,
              decoded <= limits.documentDecoded - own.reduce(0, { $0 + $1.decoded }),
              encoded <= limits.documentEncoded - own.reduce(0, { $0 + $1.encoded }) else { return false }
        charges[id] = Charge(owner: owner, decoded: decoded, encoded: encoded)
        decodedBytes += decoded
        encodedBytes += encoded
        return true
    }

    func release(_ id: UUID) {
        guard let charge = charges.removeValue(forKey: id) else { return }
        decodedBytes -= charge.decoded
        encodedBytes -= charge.encoded
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notificationPending = false
            for callback in Array(self.observers.values) { callback() }
        }
    }
}
