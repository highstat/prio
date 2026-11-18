import Foundation

/// F2a: only decides where a new output device is inserted.
public enum HeadphoneClassifier {
    public static let speakerKeywords: [String] = [
        "speaker", "soundbar", "sound bar", "stanmore", "sync", "boom", "flip",
        "charge", "soundlink flex", "homepod", "tv", "display", "monitor", "car",
    ]

    public static let headphoneKeywords: [String] = [
        "headphone", "headset", "airpods", "earbuds", "buds", "beats", "jabra",
        "wh-", "wf-", "qc", "quietcomfort", "elite", "evolve",
    ]

    /// Headphone keywords beat speaker keywords, which beat the Bluetooth rule.
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

public enum TargetSelector {
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
