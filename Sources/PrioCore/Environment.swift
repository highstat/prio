import Foundation

/// Implemented with CoreAudio in PrioAudio and simulated in tests.
/// Implementations must never open audio streams (R2).
@MainActor
public protocol AudioSystem: AnyObject {
    func devices() -> [AudioDevice]
    func defaultDevice(_ direction: Direction) -> String?
    @discardableResult
    func setDefaultDevice(_ direction: Direction, uid: String) -> Bool
}

@MainActor
public protocol Cancellable: AnyObject {
    func cancel()
}

/// The engine's only source of time and timers (R7).
@MainActor
public protocol EngineClock: AnyObject {
    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Cancellable
}

@MainActor
public protocol StateStore: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

public struct PrioNotification: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case correction
        case lastResort
        case loopProtection
        case failure
        case switched
    }

    public var kind: Kind
    public var direction: Direction
    public var body: String
    /// The `ActionRecord.id` an Undo button would undo.
    public var undoActionID: Int?

    public init(kind: Kind, direction: Direction, body: String, undoActionID: Int? = nil) {
        self.kind = kind
        self.direction = direction
        self.body = body
        self.undoActionID = undoActionID
    }
}

@MainActor
public protocol EngineDelegate: AnyObject {
    func engineDidChange(_ engine: Engine)
    func engine(_ engine: Engine, post notification: PrioNotification)
}
