import Foundation

/// The devices present right now, indexed per direction.
struct DeviceSnapshot: Equatable {
    private(set) var byUID: [String: AudioDevice] = [:]
    private(set) var ordered: [AudioDevice] = []
    private var present: [Direction: Set<String>] = [:]
    private var usable: [Direction: Set<String>] = [:]

    init() {}

    init(_ devices: [AudioDevice]) {
        ordered = devices
        byUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        for d in Direction.allCases {
            present[d] = Set(devices.filter { $0.isEligible(for: d) }.map(\.uid))
            usable[d] = Set(devices.filter { $0.isUsable(for: d) }.map(\.uid))
        }
    }

    func present(_ d: Direction) -> Set<String> { present[d] ?? [] }
    func usable(_ d: Direction) -> Set<String> { usable[d] ?? [] }
    func eligible(_ d: Direction) -> [AudioDevice] { ordered.filter { $0.isEligible(for: d) } }

    func diff(from old: DeviceSnapshot, knownTransport: (String) -> Transport?) -> TopologyChange {
        var change = TopologyChange()
        for d in Direction.allCases {
            let added = usable(d).subtracting(old.usable(d))
            let removed = old.usable(d).subtracting(usable(d))
            let presenceDelta = present(d).symmetricDifference(old.present(d))
            change.added[d] = added
            change.removed[d] = removed
            if !presenceDelta.isEmpty { change.presenceChanged.insert(d) }
            let touched = added.union(removed).union(presenceDelta)
            if touched.contains(where: { (byUID[$0]?.transport ?? old.byUID[$0]?.transport ?? knownTransport($0)) == .bluetooth }) {
                change.involvesBluetooth = true
            }
        }
        return change
    }
}

struct TopologyChange: Equatable {
    var added: [Direction: Set<String>] = [:]
    var removed: [Direction: Set<String>] = [:]
    var presenceChanged: Set<Direction> = []
    var involvesBluetooth = false

    var isEmpty: Bool { Direction.allCases.allSatisfy { !touches($0) } }

    func touches(_ d: Direction) -> Bool {
        presenceChanged.contains(d) || !(added[d] ?? []).isEmpty || !(removed[d] ?? []).isEmpty
    }
}

/// F6: a manual pick ends when its device disconnects or a higher-ranked device connects.
enum ManualPickRule {
    static func ends(pick: String, list: RankedList, change: TopologyChange, usable: Set<String>, direction d: Direction) -> Bool {
        if !usable.contains(pick) || change.removed[d]?.contains(pick) == true { return true }
        guard let pickIndex = list.index(of: pick) else { return false }
        return (change.added[d] ?? []).contains { (list.index(of: $0) ?? Int.max) < pickIndex }
    }
}

/// F9: counts corrections and failed attempts per direction.
struct LoopProtection: Equatable {
    static let window: TimeInterval = 30
    static let limit = 3

    private(set) var attempts: [Date] = []
    private(set) var lastAttempt: Date?
    private(set) var isActive = false

    /// Returns true when this attempt activates protection.
    mutating func registerAttempt(at now: Date) -> Bool {
        attempts = recent(now) + [now]
        lastAttempt = now
        guard !isActive, attempts.count >= Self.limit else { return false }
        isActive = true
        return true
    }

    /// Protection lifts after a quiet window when a device connects or disconnects.
    mutating func topologyChanged(at now: Date) {
        guard isActive, let last = lastAttempt, now.timeIntervalSince(last) >= Self.window else { return }
        self = LoopProtection()
    }

    func recent(_ now: Date) -> [Date] {
        attempts.filter { now.timeIntervalSince($0) < Self.window }
    }
}
