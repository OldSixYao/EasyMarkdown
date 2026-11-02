import Foundation

/// One owner for the baseline, edit buffer and external version. No UI or file I/O.
public struct DocumentState: Sendable {
    public private(set) var baseline: FileSnapshot
    public var text: String
    public private(set) var external: FileSnapshot?
    public private(set) var isMissing = false

    public init(snapshot: FileSnapshot) {
        baseline = snapshot
        text = snapshot.text
    }

    public var isDirty: Bool { text != baseline.text }
    public var hasConflict: Bool { external != nil || isMissing }

    public mutating func receive(_ snapshot: FileSnapshot) {
        isMissing = false
        if snapshot.text == text {
            baseline = snapshot
            external = nil
        } else if snapshot.data == baseline.data {
            external = nil
        } else if isDirty {
            external = snapshot
        } else {
            baseline = snapshot
            text = snapshot.text
            external = nil
        }
    }

    public mutating func markMissing() { isMissing = true }

    public mutating func acceptExternal() {
        guard let external else { return }
        baseline = external
        text = external.text
        self.external = nil
        isMissing = false
    }

    public mutating func didSave(_ snapshot: FileSnapshot, savedText: String) {
        baseline = snapshot
        // A user may have continued typing while the write was in flight.
        if text == savedText { text = snapshot.text }
        external = nil
        isMissing = false
    }
}
