import Foundation

/// Orchestrates F2–F13. Talks to the OS only through `AudioSystem`, reads time
/// only through `EngineClock`, reports through `EngineDelegate`.
@MainActor
public final class Engine {
    public enum Settle {
        public static let wired: TimeInterval = 0.5
        public static let bluetooth: TimeInterval = 2.0
        public static let wake: TimeInterval = 2.0
        public static let launch: TimeInterval = 1.0
    }

    public static let historyLimit = 20
    /// F10: how long an accepted write may take to show up before it counts as failed.
    public static let verifyGrace: TimeInterval = 0.5

    private let audio: AudioSystem
    private let clock: EngineClock
    private let store: StateStore
    public weak var delegate: EngineDelegate?

    public private(set) var state = PersistedState()
    public private(set) var lastAction: ActionRecord?
    public private(set) var history: [ActionRecord] = []
    public private(set) var isSessionActive = true
    public private(set) var isStarted = false
    public private(set) var didSeedOnLaunch = false

    private var devices = DeviceSnapshot()
    private var manualPicks: [Direction: String] = [:]
    /// Last default observed or written by Prio; an event matching it is Prio's own echo (F7).
    private var lastKnownDefault: [Direction: String] = [:]
    private var lastTopologyChange: [Direction: Date] = [:]
    private var lastWake: Date?
    private var pendingCorrection: Set<Direction> = []
    private var lastResortEpisode: Set<Direction> = []
    private var loop: [Direction: LoopProtection] = [:]
    private var settleTask: Cancellable?
    private var pendingVerification: [Direction: Cancellable] = [:]
    private var settleDeadline: Date?
    private var nextActionID = 1

    public init(audio: AudioSystem, clock: EngineClock, store: StateStore) {
        self.audio = audio
        self.clock = clock
        self.store = store
    }

    // MARK: - Queries

    public var settings: PrioSettings { state.settings }
    public var now: Date { clock.now }
    public var isSettling: Bool { settleDeadline != nil }

    public func list(_ d: Direction) -> RankedList { state.list(d) }
    public func manualPick(_ d: Direction) -> String? { manualPicks[d] }
    public func currentDefault(_ d: Direction) -> String? { audio.defaultDevice(d) }
    public func isLoopProtectionActive(_ d: Direction) -> Bool { loop[d]?.isActive ?? false }

    public func target(_ d: Direction) -> Target? {
        TargetSelector.select(list: state.list(d), connected: devices.usable(d), manualPick: manualPicks[d])
    }

    /// F13: only the latest action, only while the device it restores is connected.
    public var canUndo: Bool {
        guard let a = lastAction, let uid = a.undoUID else { return false }
        return devices.usable(a.direction).contains(uid)
    }

    public func rows(_ d: Direction) -> [DeviceRow] {
        let list = state.list(d)
        let names = list.displayNames()
        let current = audio.defaultDevice(d)
        return list.entries.enumerated().map { i, e in
            DeviceRow(
                uid: e.uid, name: e.name, displayName: names[e.uid] ?? e.name,
                transport: e.transport, direction: d, rank: i + 1,
                isConnected: devices.present(d).contains(e.uid),
                isUsable: devices.usable(d).contains(e.uid),
                isDefault: current == e.uid,
                isAvoided: e.avoided,
                isManualPick: manualPicks[d] == e.uid,
                isHeadphoneLike: HeadphoneClassifier.isHeadphoneLike(name: e.name, transport: e.transport)
            )
        }
    }

    public struct LoopInfo: Equatable, Sendable {
        public var isActive: Bool
        public var recentAttempts: Int
    }

    public func loopInfo(_ d: Direction) -> LoopInfo {
        let l = loop[d] ?? LoopProtection()
        return LoopInfo(isActive: l.isActive, recentAttempts: l.recent(clock.now).count)
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        let current = audio.devices()
        if let loaded = PersistedState.decode(store.load()) {
            state = loaded
            applySnapshot(current)
            restoreManualPicks(loaded.manualPicks)
        } else {
            didSeedOnLaunch = true
            seed(current)
            devices = DeviceSnapshot(current)
        }
        rememberCurrentDefaults()
        save()
        changed()
        scheduleSettle(Settle.launch)
    }

    private func seed(_ current: [AudioDevice]) {
        let snapshot = DeviceSnapshot(current)
        for d in Direction.allCases {
            state.setList(RankedList.seeded(from: snapshot.eligible(d), defaultUID: audio.defaultDevice(d)), d)
        }
    }

    /// F6: a stored pick survives relaunch only if its device is connected now.
    private func restoreManualPicks(_ stored: [String: String]) {
        guard settings.automaticSwitching else { return }
        for d in Direction.allCases {
            if let uid = stored[d.rawValue], devices.usable(d).contains(uid) { manualPicks[d] = uid }
        }
    }

    private func rememberCurrentDefaults() {
        for d in Direction.allCases { lastKnownDefault[d] = audio.defaultDevice(d) }
    }

    @discardableResult
    private func applySnapshot(_ current: [AudioDevice]) -> TopologyChange {
        let new = DeviceSnapshot(current)
        let change = new.diff(from: devices) { [state] uid in
            state.inputList.entry(uid)?.transport ?? state.outputList.entry(uid)?.transport
        }
        devices = new
        learnAndRefresh()
        return change
    }

    private func learnAndRefresh() {
        var changedAny = false
        for d in Direction.allCases {
            var list = state.list(d)
            for device in devices.eligible(d) {
                if list.contains(device.uid) { list.refresh(from: device) } else { list.learn(device, direction: d) }
            }
            if list != state.list(d) {
                state.setList(list, d)
                changedAny = true
            }
        }
        if changedAny { save() }
    }

    // MARK: - OS events

    public func devicesDidChange() {
        guard isStarted, isSessionActive else { return }
        let change = applySnapshot(audio.devices())
        guard !change.isEmpty else { return changed() }
        let now = clock.now
        for d in Direction.allCases where change.touches(d) { lastTopologyChange[d] = now }
        for d in Direction.allCases { loop[d, default: LoopProtection()].topologyChanged(at: now) }
        endManualPicks(after: change)
        scheduleSettle(change.involvesBluetooth ? Settle.bluetooth : Settle.wired)
        changed()
    }

    private func endManualPicks(after change: TopologyChange) {
        var ended = false
        for (d, pick) in manualPicks
        where ManualPickRule.ends(pick: pick, list: state.list(d), change: change, usable: devices.usable(d), direction: d) {
            manualPicks[d] = nil
            ended = true
        }
        if ended { save() }
    }

    public func defaultDidChange(_ d: Direction) {
        guard isStarted, isSessionActive else { return }
        devicesDidChange() // the default-changed callback can arrive before the device-list one
        let actual = audio.defaultDevice(d)
        let previous = lastKnownDefault[d]
        guard actual != previous else { return }
        lastKnownDefault[d] = actual
        changed()
        guard settings.automaticSwitching, let actual, let target = target(d) else { return }
        let decision = ExternalChangePolicy.decide(ExternalChange(
            isTarget: target.uid == actual,
            previousStillConnected: previous.map { devices.usable(d).contains($0) } ?? false,
            attribution: Attribution.of(now: clock.now, lastTopologyChange: lastTopologyChange[d], lastWake: lastWake),
            respectsExternalChanges: settings.respectsExternalChanges(d),
            loopProtectionActive: isLoopProtectionActive(d)
        ))
        apply(decision, d, actual)
    }

    private func apply(_ decision: ExternalChangeDecision, _ d: Direction, _ actual: String) {
        switch decision {
        case .alreadyOnTarget, .fallback:
            pendingCorrection.remove(d)
            evaluateUnlessSettling(d)
        case .correct:
            pendingCorrection.insert(d)
            evaluateUnlessSettling(d)
        case .adoptAsManualPick:
            pendingCorrection.remove(d)
            manualPicks[d] = actual
            save()
            changed()
        case .leaveAlone:
            break
        }
    }

    private func evaluateUnlessSettling(_ d: Direction) {
        if !isSettling { evaluate(d) }
    }

    public func systemWillSleep() {
        cancelSettle()
        pendingCorrection = []
    }

    public func systemDidWake() {
        guard isStarted else { return }
        lastWake = clock.now
        if isSessionActive { scheduleSettle(Settle.wake) }
    }

    public func sessionDidResignActive() {
        isSessionActive = false
        cancelSettle()
        pendingCorrection = []
        changed()
    }

    /// F12: the old Undo is stale and loop protection starts over.
    public func sessionDidBecomeActive() {
        guard !isSessionActive else { return }
        isSessionActive = true
        guard isStarted else { return }
        lastAction = nil
        loop = [:]
        endManualPicks(after: applySnapshot(audio.devices()))
        rememberCurrentDefaults()
        evaluateAll()
        changed()
    }

    // MARK: - Settling (F8)

    /// A new event restarts the wait but never shortens a longer pending one.
    private func scheduleSettle(_ delay: TimeInterval) {
        let deadline = clock.now.addingTimeInterval(delay)
        if let existing = settleDeadline, existing >= deadline { return }
        settleTask?.cancel()
        settleDeadline = deadline
        settleTask = clock.schedule(after: delay) { [weak self] in
            self?.cancelSettle()
            self?.evaluateAll()
        }
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        settleDeadline = nil
    }

    // MARK: - Evaluation (F4, F5)

    private func evaluateAll() {
        for d in Direction.allCases { evaluate(d) }
    }

    private func evaluate(_ d: Direction) {
        let correcting = pendingCorrection.remove(d) != nil && !isLoopProtectionActive(d)
        guard isSessionActive, settings.automaticSwitching else { return }
        dropDisconnectedManualPick(d)
        guard let target = target(d) else { return }
        if !target.isLastResort { lastResortEpisode.remove(d) }
        let current = audio.defaultDevice(d)
        lastKnownDefault[d] = current
        if current == target.uid {
            announceLastResortIfNew(d, target)
            return changed()
        }
        let kind: ActionRecord.Kind = correcting ? .corrected : (target.isLastResort ? .lastResort : .switched)
        perform(kind, d, to: target.uid, from: current)
    }

    private func dropDisconnectedManualPick(_ d: Direction) {
        guard let pick = manualPicks[d], !devices.usable(d).contains(pick) else { return }
        manualPicks[d] = nil
        save()
    }

    /// F5: one notice per episode, even when macOS already selected the avoided device.
    private func announceLastResortIfNew(_ d: Direction, _ target: Target, action: ActionRecord? = nil) {
        guard target.isLastResort, !lastResortEpisode.contains(d) else { return }
        lastResortEpisode.insert(d)
        let a = action ?? record(.lastResort, d, from: nil, to: target.uid, undo: nil)
        post(.lastResort, d, a)
    }

    private func perform(_ kind: ActionRecord.Kind, _ d: Direction, to uid: String, from: String?) {
        write(d, uid) { [weak self] applied in
            guard let self else { return }
            guard applied else { return self.fail(d, uid, from: from) }
            self.succeed(kind, d, to: uid, from: from)
        }
    }

    private func succeed(_ kind: ActionRecord.Kind, _ d: Direction, to uid: String, from: String?) {
        let a = record(kind, d, from: from, to: uid, undo: from)
        switch kind {
        case .corrected:
            post(.correction, d, a, offersUndo: true)
            registerAttempt(d)
        case .lastResort:
            announceLastResortIfNew(d, Target(uid: uid, reason: .lastResort), action: a)
        case .switched where settings.notifyOnEverySwitch:
            post(.switched, d, a)
        default:
            break
        }
        save()
        changed()
    }

    /// F10: verified by reading the default back. The write is tracked first because its echo
    /// may arrive re-entrantly, and an accepted write gets `verifyGrace` to show up.
    private func write(_ d: Direction, _ uid: String, then finish: @escaping (Bool) -> Void) {
        pendingVerification[d]?.cancel()
        pendingVerification[d] = nil
        lastKnownDefault[d] = uid
        let accepted = audio.setDefaultDevice(d, uid: uid)
        if audio.defaultDevice(d) == uid { return finish(true) }
        guard accepted else {
            lastKnownDefault[d] = audio.defaultDevice(d)
            return finish(false)
        }
        pendingVerification[d] = clock.schedule(after: Self.verifyGrace) { [weak self] in
            guard let self else { return }
            self.pendingVerification[d] = nil
            let actual = self.audio.defaultDevice(d)
            if actual != uid { self.lastKnownDefault[d] = actual }
            finish(actual == uid)
        }
    }

    private func fail(_ d: Direction, _ uid: String, from: String?) {
        let a = record(.failed, d, from: from, to: uid, undo: nil)
        post(.failure, d, a)
        registerAttempt(d)
        save()
        changed()
    }

    private func registerAttempt(_ d: Direction) {
        guard loop[d, default: LoopProtection()].registerAttempt(at: clock.now) else { return }
        let a = record(.loopStopped, d, from: nil, to: nil, undo: nil, makeLatest: false)
        post(.loopProtection, d, a)
    }

    // MARK: - User actions

    /// F6: a menu pick switches now; it is pinned only while automatic switching is on.
    public func pick(_ uid: String, _ d: Direction) {
        guard isStarted, devices.usable(d).contains(uid) else { return }
        pendingCorrection.remove(d)
        let before = audio.defaultDevice(d)
        guard before != uid else { return pin(uid, d) }
        write(d, uid) { [weak self] applied in
            guard let self else { return }
            guard applied else { return self.fail(d, uid, from: before) }
            self.record(.picked, d, from: before, to: uid, undo: nil)
            self.pin(uid, d)
        }
    }

    private func pin(_ uid: String, _ d: Direction) {
        if settings.automaticSwitching { manualPicks[d] = uid }
        save()
        changed()
    }

    /// F13: restores the device selected before the latest action and pins it.
    public func undo(actionID: Int? = nil) {
        guard canUndo, let a = lastAction, let uid = a.undoUID, actionID == nil || actionID == a.id else { return }
        let d = a.direction
        pendingCorrection.remove(d)
        let before = audio.defaultDevice(d)
        write(d, uid) { [weak self] applied in
            guard let self else { return }
            guard applied else { return self.fail(d, uid, from: before) }
            self.record(.undone, d, from: before, to: uid, undo: nil)
            self.pin(uid, d)
        }
    }

    // MARK: - Ranking edits (F17), each re-evaluates (F4)

    public func move(_ d: Direction, fromOffsets source: IndexSet, toOffset destination: Int) {
        edit(d) { $0.move(fromOffsets: source, toOffset: destination) }
    }

    public func moveUp(_ uid: String, _ d: Direction) { edit(d) { $0.moveUp(uid) } }
    public func moveDown(_ uid: String, _ d: Direction) { edit(d) { $0.moveDown(uid) } }
    public func moveToTop(_ uid: String, _ d: Direction) { edit(d) { $0.moveToTop(uid) } }

    /// F5: avoiding the manual pick clears it.
    public func setAvoided(_ uid: String, _ d: Direction, _ avoided: Bool) {
        if avoided && manualPicks[d] == uid { manualPicks[d] = nil }
        edit(d) { $0.setAvoided(uid, avoided) }
    }

    /// F2: only disconnected devices can be forgotten.
    public func forget(_ uid: String, _ d: Direction) {
        guard !devices.present(d).contains(uid) else { return }
        if manualPicks[d] == uid { manualPicks[d] = nil }
        var list = state.list(d)
        guard list.remove(uid) else { return }
        state.setList(list, d)
        save()
        changed()
    }

    private func edit(_ d: Direction, _ change: (inout RankedList) -> Bool) {
        var list = state.list(d)
        guard change(&list) else { return }
        state.setList(list, d)
        save()
        evaluate(d)
        changed()
    }

    // MARK: - Settings (F11)

    public func setAutomaticSwitching(_ on: Bool) {
        guard state.settings.automaticSwitching != on else { return }
        state.settings.automaticSwitching = on
        manualPicks = [:]
        pendingCorrection = []
        lastResortEpisode = []
        loop = [:]
        save()
        if on { evaluateAll() }
        changed()
    }

    public func updateSettings(_ mutate: (inout PrioSettings) -> Void) {
        var s = state.settings
        mutate(&s)
        let automatic = s.automaticSwitching
        s.automaticSwitching = state.settings.automaticSwitching
        if s != state.settings {
            state.settings = s
            save()
            changed()
        }
        setAutomaticSwitching(automatic)
    }

    // MARK: - Recording and output

    @discardableResult
    private func record(
        _ kind: ActionRecord.Kind, _ d: Direction, from: String?, to: String?, undo: String?,
        makeLatest: Bool = true
    ) -> ActionRecord {
        let a = ActionRecord(
            id: nextActionID, date: clock.now, kind: kind, direction: d,
            fromUID: from, fromName: from.map(name(of:)),
            toUID: to, toName: to.map(name(of:)),
            undoUID: undo
        )
        nextActionID += 1
        if makeLatest { lastAction = a }
        history = Array((history + [a]).suffix(Self.historyLimit))
        return a
    }

    private func name(of uid: String) -> String {
        devices.byUID[uid]?.name ?? state.inputList.entry(uid)?.name ?? state.outputList.entry(uid)?.name ?? uid
    }

    private func post(_ kind: PrioNotification.Kind, _ d: Direction, _ a: ActionRecord, offersUndo: Bool = false) {
        guard settings.notificationsEnabled else { return }
        delegate?.engine(self, post: PrioNotification(
            kind: kind, direction: d, body: NotificationText.body(kind, a),
            undoActionID: offersUndo ? a.id : nil
        ))
    }

    private func save() {
        state.manualPicks = Dictionary(uniqueKeysWithValues: manualPicks.map { ($0.key.rawValue, $0.value) })
        store.save(state.encoded())
    }

    private func changed() {
        delegate?.engineDidChange(self)
    }
}

enum NotificationText {
    static func body(_ kind: PrioNotification.Kind, _ a: ActionRecord) -> String {
        let dir = a.direction.lowercaseLabel
        switch kind {
        case .lastResort:
            return "Using \(a.toName ?? "an avoided device") for \(dir). It’s set to avoid, but nothing else is connected."
        case .loopProtection:
            return "Stopped correcting \(dir). Another app or macOS keeps changing it."
        case .correction, .failure, .switched:
            return a.sentence
        }
    }
}

/// A ranked entry joined with live state, for the UI.
public struct DeviceRow: Identifiable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var displayName: String
    public var transport: Transport
    public var direction: Direction
    public var rank: Int
    public var isConnected: Bool
    public var isUsable: Bool
    public var isDefault: Bool
    public var isAvoided: Bool
    public var isManualPick: Bool
    public var isHeadphoneLike: Bool

    public var id: String { "\(direction.rawValue):\(uid)" }

    public enum Status: String, Sendable {
        case inUse = "In use"
        case connected = "Connected"
        case notConnected = "Not connected"
    }

    public var status: Status {
        guard isConnected else { return .notConnected }
        return isDefault ? .inUse : .connected
    }

    /// VoiceOver summary, e.g. "AirPods, rank 2, connected, avoided".
    public var accessibilitySummary: String {
        var parts = [displayName, "rank \(rank)", status.rawValue.lowercased()]
        if isAvoided { parts.append("avoided") }
        if isManualPick { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}
