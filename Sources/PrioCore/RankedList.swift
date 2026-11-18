import Foundation

/// Index 0 is rank 1.
public struct RankedList: Codable, Equatable, Sendable {
    public var entries: [RankedEntry]

    public init(_ entries: [RankedEntry] = []) {
        self.entries = entries
    }

    public var uids: [String] { entries.map(\.uid) }

    public func contains(_ uid: String) -> Bool { index(of: uid) != nil }

    public func index(of uid: String) -> Int? { entries.firstIndex { $0.uid == uid } }

    public func entry(_ uid: String) -> RankedEntry? { entries.first { $0.uid == uid } }

    public func rank(of uid: String) -> Int? { index(of: uid).map { $0 + 1 } }

    public mutating func append(_ entry: RankedEntry) {
        guard !contains(entry.uid) else { return }
        entries.append(entry)
    }

    public mutating func insertAtTop(_ entry: RankedEntry) {
        guard !contains(entry.uid) else { return }
        entries.insert(entry, at: 0)
    }

    /// Same semantics as SwiftUI `onMove`.
    @discardableResult
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) -> Bool {
        let before = uids
        let moving = source.sorted().filter { $0 >= 0 && $0 < entries.count }.map { entries[$0] }
        guard !moving.isEmpty else { return false }
        let clamped = max(0, min(destination, entries.count))
        let removedBefore = source.filter { $0 < clamped }.count
        var remaining = entries
        for i in source.sorted(by: >) where i >= 0 && i < remaining.count {
            remaining.remove(at: i)
        }
        remaining.insert(contentsOf: moving, at: clamped - removedBefore)
        entries = remaining
        return uids != before
    }

    @discardableResult
    public mutating func move(_ uid: String, to newIndex: Int) -> Bool {
        guard let from = index(of: uid) else { return false }
        let target = max(0, min(newIndex, entries.count - 1))
        guard target != from else { return false }
        let e = entries.remove(at: from)
        entries.insert(e, at: target)
        return true
    }

    @discardableResult
    public mutating func moveUp(_ uid: String) -> Bool {
        guard let i = index(of: uid) else { return false }
        return move(uid, to: i - 1)
    }

    @discardableResult
    public mutating func moveDown(_ uid: String) -> Bool {
        guard let i = index(of: uid) else { return false }
        return move(uid, to: i + 1)
    }

    @discardableResult
    public mutating func moveToTop(_ uid: String) -> Bool { move(uid, to: 0) }

    @discardableResult
    public mutating func remove(_ uid: String) -> Bool {
        guard let i = index(of: uid) else { return false }
        entries.remove(at: i)
        return true
    }

    @discardableResult
    public mutating func setAvoided(_ uid: String, _ avoided: Bool) -> Bool {
        guard let i = index(of: uid), entries[i].avoided != avoided else { return false }
        entries[i].avoided = avoided
        return true
    }

    /// F2: new headphone-like outputs go to the top, everything else to the bottom.
    public mutating func learn(_ device: AudioDevice, direction: Direction) {
        let entry = RankedEntry(uid: device.uid, name: device.name, transport: device.transport)
        if direction == .output && HeadphoneClassifier.isHeadphoneLike(device) {
            insertAtTop(entry)
        } else {
            append(entry)
        }
    }

    /// F2 first launch: the current default first, then the OS order.
    public static func seeded(from eligible: [AudioDevice], defaultUID: String?) -> RankedList {
        let first = eligible.filter { $0.uid == defaultUID }
        var list = RankedList()
        for device in first + eligible {
            list.append(RankedEntry(uid: device.uid, name: device.name, transport: device.transport))
        }
        return list
    }

    public mutating func refresh(from device: AudioDevice) {
        guard let i = index(of: device.uid) else { return }
        entries[i].name = device.name
        entries[i].transport = device.transport
    }

    /// F17: later duplicates by rank get " (2)", " (3)"…
    public func displayNames() -> [String: String] {
        var seen: [String: Int] = [:]
        var result: [String: String] = [:]
        for e in entries {
            let key = e.name.lowercased()
            let n = (seen[key] ?? 0) + 1
            seen[key] = n
            result[e.uid] = n == 1 ? e.name : "\(e.name) (\(n))"
        }
        return result
    }
}
