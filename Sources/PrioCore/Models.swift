import Foundation

/// Input (microphones) or output (speakers, headphones).
public enum Direction: String, Codable, CaseIterable, Sendable, Hashable {
    case input
    case output

    public var label: String { self == .input ? "Input" : "Output" }
    public var lowercaseLabel: String { rawValue }
}

/// How a device is attached. Maps the many CoreAudio transport types onto the
/// labels Prio shows (F17).
public enum Transport: String, Codable, CaseIterable, Sendable, Hashable {
    case builtIn
    case usb
    case bluetooth
    case hdmiDisplayPort
    case thunderbolt
    case airPlay
    case virtual
    case aggregate
    case other

    public var label: String {
        switch self {
        case .builtIn: return "Built-in"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .hdmiDisplayPort: return "HDMI/DisplayPort"
        case .thunderbolt: return "Thunderbolt"
        case .airPlay: return "AirPlay"
        case .virtual: return "Virtual"
        case .aggregate: return "Aggregate"
        case .other: return "Other"
        }
    }

    public init(from decoder: Decoder) throws {
        // Unknown values from a newer version decode as `.other` instead of failing.
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Transport(rawValue: raw) ?? .other
    }
}

/// A snapshot of one device as the OS reports it right now.
public struct AudioDevice: Equatable, Sendable, Hashable {
    /// Stable, persistent unique identifier (CoreAudio device UID).
    public var uid: String
    public var name: String
    public var transport: Transport
    public var hasInput: Bool
    public var hasOutput: Bool
    public var canBeDefaultInput: Bool
    public var canBeDefaultOutput: Bool
    public var isHidden: Bool
    /// False while a device is present but not ready to carry audio
    /// (e.g. a Bluetooth headset still negotiating). Prio never switches to it.
    public var isAlive: Bool
    /// Built-in output only: the active data source is the headphone jack.
    public var dataSourceIsHeadphones: Bool

    public init(
        uid: String,
        name: String,
        transport: Transport,
        hasInput: Bool = false,
        hasOutput: Bool = false,
        canBeDefaultInput: Bool? = nil,
        canBeDefaultOutput: Bool? = nil,
        isHidden: Bool = false,
        isAlive: Bool = true,
        dataSourceIsHeadphones: Bool = false
    ) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.canBeDefaultInput = canBeDefaultInput ?? hasInput
        self.canBeDefaultOutput = canBeDefaultOutput ?? hasOutput
        self.isHidden = isHidden
        self.isAlive = isAlive
        self.dataSourceIsHeadphones = dataSourceIsHeadphones
    }

    /// Whether the device belongs in the ranked list for `direction` (F2).
    public func isEligible(for direction: Direction) -> Bool {
        if isHidden { return false }
        switch direction {
        case .input: return hasInput && canBeDefaultInput
        case .output: return hasOutput && canBeDefaultOutput
        }
    }

    /// Eligible and ready to be selected (F8: not-yet-usable devices are skipped).
    public func isUsable(for direction: Direction) -> Bool {
        isEligible(for: direction) && isAlive
    }
}

/// One row of a ranked list, persisted.
public struct RankedEntry: Codable, Equatable, Sendable, Hashable, Identifiable {
    public var uid: String
    public var name: String
    public var transport: Transport
    public var avoided: Bool

    public var id: String { uid }

    public init(uid: String, name: String, transport: Transport, avoided: Bool = false) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.avoided = avoided
    }

    enum CodingKeys: String, CodingKey { case uid, name, transport, avoided }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(String.self, forKey: .uid)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? uid
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .other
        avoided = try c.decodeIfPresent(Bool.self, forKey: .avoided) ?? false
    }
}

/// User-facing settings (F11, F14, F7, F18).
public struct PrioSettings: Codable, Equatable, Sendable {
    public var automaticSwitching: Bool = true
    public var notificationsEnabled: Bool = true
    public var notifyOnEverySwitch: Bool = false
    public var respectOutputChanges: Bool = true
    public var respectInputChanges: Bool = false

    public init() {}

    public func respectsExternalChanges(_ direction: Direction) -> Bool {
        direction == .output ? respectOutputChanges : respectInputChanges
    }

    enum CodingKeys: String, CodingKey {
        case automaticSwitching, notificationsEnabled, notifyOnEverySwitch
        case respectOutputChanges, respectInputChanges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrioSettings()
        automaticSwitching = try c.decodeIfPresent(Bool.self, forKey: .automaticSwitching) ?? d.automaticSwitching
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        notifyOnEverySwitch = try c.decodeIfPresent(Bool.self, forKey: .notifyOnEverySwitch) ?? d.notifyOnEverySwitch
        respectOutputChanges = try c.decodeIfPresent(Bool.self, forKey: .respectOutputChanges) ?? d.respectOutputChanges
        respectInputChanges = try c.decodeIfPresent(Bool.self, forKey: .respectInputChanges) ?? d.respectInputChanges
    }
}
