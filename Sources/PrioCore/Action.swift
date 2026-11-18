import Foundation

/// Stored as data, not text, so diagnostics can render it without device names.
public struct ActionRecord: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case switched
        case corrected
        case lastResort
        case failed
        case undone
        case picked
        /// Loop protection kicked in (F9). History only.
        case loopStopped
    }

    public var id: Int
    public var date: Date
    public var kind: Kind
    public var direction: Direction
    /// Device selected before the action (for corrections: what macOS chose).
    public var fromUID: String?
    public var fromName: String?
    public var toUID: String?
    public var toName: String?
    public var undoUID: String?

    public init(
        id: Int, date: Date, kind: Kind, direction: Direction,
        fromUID: String? = nil, fromName: String? = nil,
        toUID: String? = nil, toName: String? = nil,
        undoUID: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.direction = direction
        self.fromUID = fromUID
        self.fromName = fromName
        self.toUID = toUID
        self.toName = toName
        self.undoUID = undoUID
    }

    /// `name` maps (uid, stored name) to display text, so callers can anonymize.
    public func sentence(name: (String?, String?) -> String) -> String {
        let to = name(toUID, toName)
        let from = name(fromUID, fromName)
        let dir = direction.lowercaseLabel
        switch kind {
        case .switched:
            if fromUID != nil {
                return "Switched \(dir) from \(from) to \(to)."
            }
            return "Switched \(dir) to \(to)."
        case .corrected:
            return "macOS picked \(from) for \(dir). Prio kept \(to)."
        case .lastResort:
            return "Using \(to) for \(dir) as a last resort."
        case .failed:
            return "Couldn’t switch \(dir) to \(to)."
        case .undone:
            return "Undone. \(direction.label) is back on \(to)."
        case .picked:
            return "You picked \(to) for \(dir)."
        case .loopStopped:
            return "Stopped correcting \(dir). Something keeps changing it."
        }
    }

    public var sentence: String {
        sentence { uid, stored in stored ?? uid ?? "an unknown device" }
    }
}

public struct PersistedState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = PersistedState.currentVersion
    public var inputList: RankedList = RankedList()
    public var outputList: RankedList = RankedList()
    public var settings: PrioSettings = PrioSettings()
    /// Keyed by `Direction.rawValue`.
    public var manualPicks: [String: String] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case version, inputList, outputList, settings, manualPicks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PersistedState.currentVersion
        inputList = try c.decodeIfPresent(RankedList.self, forKey: .inputList) ?? RankedList()
        outputList = try c.decodeIfPresent(RankedList.self, forKey: .outputList) ?? RankedList()
        settings = try c.decodeIfPresent(PrioSettings.self, forKey: .settings) ?? PrioSettings()
        manualPicks = try c.decodeIfPresent([String: String].self, forKey: .manualPicks) ?? [:]
    }

    public func list(_ d: Direction) -> RankedList { d == .input ? inputList : outputList }

    public mutating func setList(_ list: RankedList, _ d: Direction) {
        if d == .input { inputList = list } else { outputList = list }
    }

    public func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data?) -> PersistedState? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }
}
