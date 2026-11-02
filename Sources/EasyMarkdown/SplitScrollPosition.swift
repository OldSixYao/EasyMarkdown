import Foundation

/// A UTF-16 source position with fractional progress within a source line/block.
struct SplitScrollPosition: Sendable {
    let offset: Double
    let progress: Double

    init(offset: Double, progress: Double) {
        self.offset = offset.isFinite ? max(0, offset) : 0
        self.progress = progress.isFinite ? min(1, max(0, progress)) : 0
    }

    var arguments: [String: Any] { ["offset": offset, "progress": progress] }
}
