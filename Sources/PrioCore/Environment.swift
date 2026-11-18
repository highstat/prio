import Foundation

/// Abstract view of the OS audio device system. The real implementation lives
/// in PrioAudio (CoreAudio); tests use a simulated one.
/// Implementations must never open audio streams (R2).
@MainActor
public protocol AudioSystem: AnyObject {
    /// All devices currently present, in the order the OS reports them.
    func devices() -> [AudioDevice]
    /// UID of the current system default device for a direction.
    func defaultDevice(_ direction: Direction) -> String?
    /// Ask the OS to change the default. Returns false if the request was refused.
    /// The engine verifies the result by reading `defaultDevice` back (F10).
    @discardableResult
    func setDefaultDevice(_ direction: Direction, uid: String) -> Bool
}

/// Cancellation handle for a scheduled callback.
@MainActor
public protocol Cancellable: AnyObject {
    func cancel()
}

/// Injected time source and timer (R7). The engine never reads the wall clock
/// or creates timers on its own.
@MainActor
public protocol EngineClock: AnyObject {
    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Cancellable
}

/// Loads and saves the persisted state blob (section 7).
@MainActor
public protocol StateStore: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

/// A user-visible notification the engine wants posted (F14). The app maps
/// it onto the system notification center.
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
    public var title: String
    public var body: String
    /// Set when the notification should carry an Undo button. Matches
    /// `ActionRecord.id` of the action it would undo.
    public var undoActionID: Int?

    public init(kind: Kind, direction: Direction, title: String, body: String, undoActionID: Int? = nil) {
        self.kind = kind
        self.direction = direction
        self.title = title
        self.body = body
        self.undoActionID = undoActionID
    }
}

@MainActor
public protocol EngineDelegate: AnyObject {
    /// Called when anything observable changed (lists, defaults, last action…).
    func engineDidChange(_ engine: Engine)
    /// Called for notifications that pass the user's notification settings.
    func engine(_ engine: Engine, post notification: PrioNotification)
}
