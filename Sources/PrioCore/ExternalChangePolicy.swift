import Foundation

/// Who most likely changed the default device (F7). macOS gives no direct signal.
public enum Attribution: Equatable, Sendable {
    case macOS
    case user

    public static let topologyWindow: TimeInterval = 3.0
    public static let wakeWindow: TimeInterval = 5.0

    public static func of(now: Date, lastTopologyChange: Date?, lastWake: Date?) -> Attribution {
        if let t = lastTopologyChange, now.timeIntervalSince(t) <= topologyWindow { return .macOS }
        if let w = lastWake, now.timeIntervalSince(w) <= wakeWindow { return .macOS }
        return .user
    }
}

/// A default-device change Prio did not initiate.
public struct ExternalChange: Equatable, Sendable {
    public var isTarget: Bool
    public var previousStillConnected: Bool
    public var attribution: Attribution
    public var respectsExternalChanges: Bool
    public var loopProtectionActive: Bool

    public init(isTarget: Bool, previousStillConnected: Bool, attribution: Attribution, respectsExternalChanges: Bool, loopProtectionActive: Bool) {
        self.isTarget = isTarget
        self.previousStillConnected = previousStillConnected
        self.attribution = attribution
        self.respectsExternalChanges = respectsExternalChanges
        self.loopProtectionActive = loopProtectionActive
    }
}

public enum ExternalChangeDecision: Equatable, Sendable {
    case alreadyOnTarget
    /// The previous default disappeared, so macOS had to pick something: a ranking switch, not a correction.
    case fallback
    case adoptAsManualPick
    case correct
    case leaveAlone
}

public enum ExternalChangePolicy {
    public static func decide(_ change: ExternalChange) -> ExternalChangeDecision {
        if change.isTarget { return .alreadyOnTarget }
        if !change.previousStillConnected { return .fallback }
        if change.attribution == .user && change.respectsExternalChanges { return .adoptAsManualPick }
        return change.loopProtectionActive ? .leaveAlone : .correct
    }
}
