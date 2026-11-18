import Foundation
@testable import PrioCore

// MARK: - Controllable clock

@MainActor
final class TestClock: EngineClock {
    final class Task: Cancellable {
        let fireAt: Date
        let seq: Int
        let action: @MainActor () -> Void
        var cancelled = false
        init(fireAt: Date, seq: Int, action: @escaping @MainActor () -> Void) {
            self.fireAt = fireAt
            self.seq = seq
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private(set) var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var tasks: [Task] = []
    private var seq = 0

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Cancellable {
        seq += 1
        let t = Task(fireAt: now.addingTimeInterval(seconds), seq: seq, action: action)
        tasks.append(t)
        return t
    }

    /// Advance time, firing due callbacks in order.
    func advance(by seconds: TimeInterval, beforeEach: () -> Void = {}) {
        let end = now.addingTimeInterval(seconds)
        while true {
            tasks.removeAll { $0.cancelled }
            guard let next = tasks.filter({ $0.fireAt <= end }).min(by: { ($0.fireAt, $0.seq) < ($1.fireAt, $1.seq) }) else { break }
            tasks.removeAll { $0 === next }
            now = max(now, next.fireAt)
            beforeEach()
            next.action()
        }
        now = end
    }

    var pendingCount: Int { tasks.filter { !$0.cancelled }.count }
}

// MARK: - Simulated device system

@MainActor
final class FakeAudioSystem: AudioSystem {
    enum EchoMode {
        /// Default-changed callback for our own writes is queued and delivered on `flush()`.
        case async
        /// Delivered re-entrantly inside `setDefaultDevice`.
        case reentrant
        /// Never delivered.
        case none
    }

    enum Event: Equatable {
        case devices
        case defaultChanged(Direction)
    }

    weak var engine: Engine?
    var deviceList: [AudioDevice] = []
    var defaults: [Direction: String] = [:]
    /// UIDs the OS refuses to make default (F10).
    var refuse: Set<String> = []
    var echoMode: EchoMode = .async
    /// When the default device disconnects, act like macOS and pick another.
    var macOSFallbackOnDisconnect = true
    /// Deliver default-changed before devices-changed on disconnect.
    var defaultEventFirst = false
    private(set) var queued: [Event] = []
    private(set) var setCalls: [(Direction, String)] = []

    func devices() -> [AudioDevice] { deviceList }

    func defaultDevice(_ direction: Direction) -> String? { defaults[direction] }

    func setDefaultDevice(_ direction: Direction, uid: String) -> Bool {
        setCalls.append((direction, uid))
        guard !refuse.contains(uid), deviceList.contains(where: { $0.uid == uid && $0.isUsable(for: direction) }) else {
            return false
        }
        guard defaults[direction] != uid else { return true }
        defaults[direction] = uid
        switch echoMode {
        case .async: queued.append(.defaultChanged(direction))
        case .reentrant: engine?.defaultDidChange(direction)
        case .none: break
        }
        return true
    }

    func setCount(_ d: Direction? = nil) -> Int {
        setCalls.filter { d == nil || $0.0 == d }.count
    }

    /// Deliver queued listener callbacks.
    func flush() {
        while !queued.isEmpty {
            let e = queued.removeFirst()
            switch e {
            case .devices: engine?.devicesDidChange()
            case .defaultChanged(let d): engine?.defaultDidChange(d)
            }
        }
    }

    // Simulation helpers (deliver events immediately, like listener callbacks).

    func connect(_ device: AudioDevice, macOSSelects: [Direction] = []) {
        deviceList.removeAll { $0.uid == device.uid }
        deviceList.append(device)
        for d in macOSSelects { defaults[d] = device.uid }
        flush()
        engine?.devicesDidChange()
        for d in macOSSelects { engine?.defaultDidChange(d) }
    }

    func disconnect(_ uid: String) {
        deviceList.removeAll { $0.uid == uid }
        var changed: [Direction] = []
        for d in Direction.allCases where defaults[d] == uid {
            defaults[d] = macOSFallbackOnDisconnect ? deviceList.first(where: { $0.isUsable(for: d) })?.uid : nil
            changed.append(d)
        }
        flush()
        if defaultEventFirst {
            for d in changed { engine?.defaultDidChange(d) }
            engine?.devicesDidChange()
        } else {
            engine?.devicesDidChange()
            for d in changed { engine?.defaultDidChange(d) }
        }
    }

    func setAlive(_ uid: String, _ alive: Bool) {
        guard let i = deviceList.firstIndex(where: { $0.uid == uid }) else { return }
        deviceList[i].isAlive = alive
        flush()
        engine?.devicesDidChange()
    }

    /// Another app, macOS, or the user in System Settings changes the default.
    func externalSet(_ d: Direction, _ uid: String) {
        flush()
        defaults[d] = uid
        engine?.defaultDidChange(d)
    }
}

// MARK: - Storage and delegate

@MainActor
final class MemoryStore: StateStore {
    var data: Data?
    private(set) var saveCount = 0
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) {
        self.data = data
        saveCount += 1
    }
}

@MainActor
final class RecordingDelegate: EngineDelegate {
    var notifications: [PrioNotification] = []
    var changeCount = 0
    func engineDidChange(_ engine: Engine) { changeCount += 1 }
    func engine(_ engine: Engine, post notification: PrioNotification) { notifications.append(notification) }

    func count(_ kind: PrioNotification.Kind) -> Int { notifications.filter { $0.kind == kind }.count }
}

// MARK: - Devices

enum Dev {
    static func mic(_ uid: String, _ name: String? = nil, transport: Transport = .usb) -> AudioDevice {
        AudioDevice(uid: uid, name: name ?? uid, transport: transport, hasInput: true)
    }

    static func speaker(_ uid: String, _ name: String? = nil, transport: Transport = .usb) -> AudioDevice {
        AudioDevice(uid: uid, name: name ?? uid, transport: transport, hasOutput: true)
    }

    static func headset(_ uid: String, _ name: String, transport: Transport = .bluetooth, alive: Bool = true) -> AudioDevice {
        AudioDevice(uid: uid, name: name, transport: transport, hasInput: true, hasOutput: true, isAlive: alive)
    }

    static let builtInMic = AudioDevice(uid: "builtin-mic", name: "MacBook Pro Microphone", transport: .builtIn, hasInput: true)
    static let builtInSpeakers = AudioDevice(uid: "builtin-out", name: "MacBook Pro Speakers", transport: .builtIn, hasOutput: true)
}

// MARK: - Harness

@MainActor
final class Harness {
    let audio = FakeAudioSystem()
    let clock = TestClock()
    let store: MemoryStore
    let delegate = RecordingDelegate()
    private(set) var engine: Engine

    init(devices: [AudioDevice], input: String? = nil, output: String? = nil, stored: PersistedState? = nil, storedData: Data? = nil) {
        store = MemoryStore(storedData ?? stored?.encoded())
        audio.deviceList = devices
        if let input { audio.defaults[.input] = input }
        if let output { audio.defaults[.output] = output }
        engine = Engine(audio: audio, clock: clock, store: store)
        engine.delegate = delegate
        audio.engine = engine
    }

    /// Convenience: a harness whose ranked lists are exactly as given.
    convenience init(
        inputList: [RankedEntry] = [], outputList: [RankedEntry] = [],
        connected: [AudioDevice], input: String? = nil, output: String? = nil,
        settings: PrioSettings = PrioSettings()
    ) {
        var s = PersistedState()
        s.inputList = RankedList(inputList)
        s.outputList = RankedList(outputList)
        s.settings = settings
        self.init(devices: connected, input: input, output: output, stored: s)
    }

    /// Start and let the 1 s launch settle elapse.
    func launch(settle: Bool = true) {
        engine.start()
        if settle { advance(1.0) }
    }

    /// Simulate a relaunch with the same storage and devices.
    func relaunch() {
        engine = Engine(audio: audio, clock: clock, store: store)
        engine.delegate = delegate
        audio.engine = engine
        launch()
    }

    func advance(_ seconds: TimeInterval) {
        audio.flush()
        clock.advance(by: seconds) { [audio] in audio.flush() }
        audio.flush()
    }

    var actions: [ActionRecord] { engine.history }
    func actions(_ kind: ActionRecord.Kind) -> [ActionRecord] { engine.history.filter { $0.kind == kind } }
    func def(_ d: Direction) -> String? { audio.defaults[d] }
    func order(_ d: Direction) -> [String] { engine.list(d).uids }
}

func entry(_ uid: String, avoided: Bool = false, transport: Transport = .usb) -> RankedEntry {
    RankedEntry(uid: uid, name: uid, transport: transport, avoided: avoided)
}
