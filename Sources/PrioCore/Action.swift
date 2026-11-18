import Foundation

/// Something Prio did, stored as data (not text) so that diagnostics can
/// render it with or without device names (F13, F19).
public struct ActionRecord: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        /// Ranking-driven switch (F4).
        case switched
        /// External change attributed to macOS was reverted (F7 rule 1).
        case corrected
        /// Only avoided devices connected; using the best one (F5).
        case lastResort
        /// Setting the default did not take effect (F10).
        case failed
        /// The user pressed Undo (F13).
        case undone
        /// The user chose a device from the menu (F6).
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
    /// Device Prio selected (or tried to select).
    public var toUID: String?
    public var toName: String?
    /// Device Undo would restore, if this action can be undone.
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

    /// Short human-readable sentence. `name` maps a (uid, stored name) to the
    /// text to show, so callers can anonymize.
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

    /// Sentence with real device names.
    public var sentence: String {
        sentence { uid, stored in stored ?? uid ?? "an unknown device" }
    }
}

/// Everything Prio stores on disk (section 7).
public struct PersistedState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = PersistedState.currentVersion
    public var inputList: RankedList = RankedList()
    public var outputList: RankedList = RankedList()
    public var settings: PrioSettings = PrioSettings()
    /// Manual picks by direction raw value. Restored only if the device is
    /// connected at launch (F6).
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

    /// Returns nil for missing or corrupt data, so the caller starts fresh.
    public static func decode(_ data: Data?) -> PersistedState? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }
}
