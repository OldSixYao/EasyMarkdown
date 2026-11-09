import Foundation

/// One owner for the baseline, edit buffer and external version. No UI or file I/O.
public struct DocumentState: Sendable {
    public private(set) var baseline: FileSnapshot
    private var buffer: String
    public var text: String {
        get { buffer }
        set { edit(newValue) }
    }
    public private(set) var revision: UInt64 = 0
    public private(set) var byteCount: Int
    public private(set) var lastChange: TextChange?
    public private(set) var isDirty = false
    public private(set) var external: FileSnapshot?
    public private(set) var isMissing = false
    private var differences: [Difference] = []

    private struct Difference: Sendable {
        var start: Int
        var currentEnd: Int
        var baselineStart: Int
        var baselineEnd: Int
        var isDirty = true
        var delta: Int { currentEnd - start - (baselineEnd - baselineStart) }
    }

    public init(snapshot: FileSnapshot) {
        baseline = snapshot
        buffer = snapshot.text
        byteCount = snapshot.text.utf8.count
    }

    public var hasConflict: Bool { external != nil || isMissing }

    public mutating func edit(_ value: String, change: TextChange? = nil) {
        let oldLength = buffer.utf16.count
        buffer = value
        revision &+= 1
        if let change, change.range.location >= 0, change.range.length >= 0,
           change.range.location <= oldLength, change.range.length <= oldLength - change.range.location,
           value.utf16.count == oldLength - change.range.length + change.replacementLength {
            lastChange = change
            byteCount = max(0, byteCount + change.utf8Delta)
            updateDifferences(change)
        } else {
            lastChange = nil
            byteCount = value.utf8.count
            resetDifference()
        }
    }

    private mutating func resetDifference() {
        // Foundation compares bridged editor strings without Swift's repeated
        // per-character bridging. It also preserves canonical Unicode equality.
        isDirty = (buffer as NSString).compare(baseline.text) != .orderedSame
        if !isDirty, (buffer as NSString).isEqual(to: baseline.text) { differences = [] }
        else {
            differences = [Difference(start: 0, currentEnd: buffer.utf16.count, baselineStart: 0,
                baselineEnd: baseline.coordinates.length, isDirty: isDirty)]
        }
    }

    private mutating func updateDifferences(_ change: TextChange) {
        let start = change.range.location, end = NSMaxRange(change.range)
        let delta = change.replacementLength - change.range.length
        var first = 0, prefixDelta = 0
        while first < differences.count, differences[first].currentEnd < start {
            prefixDelta += differences[first].delta
            first += 1
        }
        var last = first, throughDelta = prefixDelta
        while last < differences.count, differences[last].start <= end {
            throughDelta += differences[last].delta
            last += 1
        }
        let left = first < last ? min(start, differences[first].start) : start
        let right = first < last ? max(end, differences[last - 1].currentEnd) : end
        var difference = Difference(start: left, currentEnd: right + delta,
            baselineStart: left - prefixDelta, baselineEnd: right - throughDelta)
        for index in last..<differences.count {
            differences[index].start += delta
            differences[index].currentEnd += delta
        }
        let current = (buffer as NSString).substring(with:
            NSRange(location: difference.start, length: difference.currentEnd - difference.start))
        let original = baseline.coordinates.substring(
            NSRange(location: difference.baselineStart, length: difference.baselineEnd - difference.baselineStart))
        difference.isDirty = current != original
        // Canonically equal text can have different UTF-16 lengths. Retain its
        // coordinate mapping until the literal code units also match.
        let replacement = !difference.isDirty && (current as NSString).isEqual(to: original) ? [] : [difference]
        differences.replaceSubrange(first..<last, with: replacement)
        isDirty = differences.contains(where: \.isDirty)
        // Bound metadata during arbitrarily scattered edits. Reconcile only at
        // this infrequent threshold rather than retaining one object per key.
        if differences.count > 256 { resetDifference() }
    }

    private mutating func follow(_ snapshot: FileSnapshot) {
        let changed = (buffer as NSString).compare(snapshot.text, options: .literal) != .orderedSame
        baseline = snapshot
        buffer = snapshot.text
        byteCount = snapshot.text.utf8.count
        if changed { revision &+= 1 }
        if changed { lastChange = nil }
        differences = []
        isDirty = false
    }

    public mutating func receive(_ snapshot: FileSnapshot) {
        isMissing = false
        if snapshot.data == baseline.data {
            external = nil
        } else if (buffer as NSString).compare(snapshot.text) == .orderedSame {
            baseline = snapshot
            resetDifference()
            external = nil
        } else if isDirty {
            external = snapshot
        } else {
            follow(snapshot)
            external = nil
        }
    }

    public mutating func markMissing() { isMissing = true }

    public mutating func acceptExternal() {
        guard let external else { return }
        follow(external)
        self.external = nil
        isMissing = false
    }

    public mutating func didSave(_ snapshot: FileSnapshot, savedText: String) {
        baseline = snapshot
        // A user may have continued typing while the write was in flight.
        if (buffer as NSString).compare(savedText) == .orderedSame { follow(snapshot) }
        else { resetDifference() }
        external = nil
        isMissing = false
    }
}
