import Foundation

/// F2a: decides whether a newly seen output device is "headphone-like", which
/// only controls where it is inserted in the output list.
public enum HeadphoneClassifier {
    public static let speakerKeywords: [String] = [
        "speaker", "soundbar", "sound bar", "stanmore", "sync", "boom", "flip",
        "charge", "soundlink flex", "homepod", "tv", "display", "monitor", "car",
    ]

    public static let headphoneKeywords: [String] = [
        "headphone", "headset", "airpods", "earbuds", "buds", "beats", "jabra",
        "wh-", "wf-", "qc", "quietcomfort", "elite", "evolve",
    ]

    /// Pure classification.
    /// - Rule 2 (headphone keyword, any transport) wins over everything.
    /// - Rule 1: Bluetooth and no speaker keyword.
    /// - Rule 3: built-in output whose data source is the headphone jack.
    public static func isHeadphoneLike(
        name: String,
        transport: Transport,
        dataSourceIsHeadphones: Bool = false
    ) -> Bool {
        let lower = name.lowercased()
        if headphoneKeywords.contains(where: { lower.contains($0) }) { return true }
        if transport == .bluetooth {
            return !speakerKeywords.contains(where: { matchesAtWordStart(lower, $0) })
        }
        if transport == .builtIn && dataSourceIsHeadphones { return true }
        return false
    }

    public static func isHeadphoneLike(_ device: AudioDevice) -> Bool {
        isHeadphoneLike(
            name: device.name,
            transport: device.transport,
            dataSourceIsHeadphones: device.dataSourceIsHeadphones
        )
    }

    /// Speaker keywords must start at a word boundary so that short keywords
    /// such as "car" or "tv" do not match inside unrelated words
    /// ("Scarlett", "Oscar's"). They may run on ("Soundbar500" matches "soundbar").
    static func matchesAtWordStart(_ haystack: String, _ keyword: String) -> Bool {
        var searchStart = haystack.startIndex
        while let r = haystack.range(of: keyword, range: searchStart..<haystack.endIndex) {
            if r.lowerBound == haystack.startIndex { return true }
            let prev = haystack[haystack.index(before: r.lowerBound)]
            if !(prev.isLetter || prev.isNumber) { return true }
            searchStart = haystack.index(after: r.lowerBound)
        }
        return false
    }
}

/// The result of target selection for one direction (F3).
public struct Target: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case manualPick
        case ranked
        case lastResort
    }

    public var uid: String
    public var reason: Reason

    public init(uid: String, reason: Reason) {
        self.uid = uid
        self.reason = reason
    }

    public var isLastResort: Bool { reason == .lastResort }
}

/// F3: pure, deterministic target selection.
public enum TargetSelector {
    /// - Parameters:
    ///   - list: the direction's ranked list (avoided flags live on the entries).
    ///   - connected: UIDs of devices that are connected and usable.
    ///   - manualPick: the current manual pick, if any. It is valid while connected.
    public static func select(list: RankedList, connected: Set<String>, manualPick: String?) -> Target? {
        if let pick = manualPick, connected.contains(pick) {
            return Target(uid: pick, reason: .manualPick)
        }
        let present = list.entries.filter { connected.contains($0.uid) }
        if let best = present.first(where: { !$0.avoided }) {
            return Target(uid: best.uid, reason: .ranked)
        }
        if let fallback = present.first {
            return Target(uid: fallback.uid, reason: .lastResort)
        }
        return nil
    }
}
