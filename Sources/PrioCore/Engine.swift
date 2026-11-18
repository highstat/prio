import Foundation

/// The decision engine (F2–F13). Pure logic: talks to the OS only through
/// `AudioSystem`, reads time only through `EngineClock`, and reports through
/// `EngineDelegate`. All methods must be called on the main actor.
@MainActor
public final class Engine {
    // MARK: Timing constants (spec values)

    public enum Timing {
        /// F8: wait after the last wired/virtual connect or disconnect.
        public static let settleWired: TimeInterval = 0.5
        /// F8: wait after the last event involving a Bluetooth device.
        public static let settleBluetooth: TimeInterval = 2.0
        /// F8: wait after wake.
        public static let settleWake: TimeInterval = 2.0
        /// F12: wait after launch.
        public static let settleLaunch: TimeInterval = 1.0
        /// F7 rule 1: a topology change this recent means macOS made the change.
        public static let topologyAttribution: TimeInterval = 3.0
        /// F7 rule 1: a wake this recent means macOS made the change.
        public static let wakeAttribution: TimeInterval = 5.0
        /// F9: window for counting corrections.
        public static let loopWindow: TimeInterval = 30.0
        /// F9: corrections within the window that trigger loop protection.
        public static let loopLimit = 3
        /// F19: actions kept for diagnostics.
        public static let historyLimit = 20
    }

    struct LoopState: Equatable {
        var attempts: [Date] = []
        var lastAttempt: Date?
        var stopped = false
    }

    struct TopologyChange {
        var added: [Direction: Set<String>] = [:]
        var removed: [Direction: Set<String>] = [:]
        var presenceChanged: Set<Direction> = []
        var involvesBluetooth = false

        var isEmpty: Bool { presenceChanged.isEmpty && added.values.allSatisfy(\.isEmpty) && removed.values.allSatisfy(\.isEmpty) }

        func touches(_ d: Direction) -> Bool {
            presenceChanged.contains(d) || !(added[d] ?? []).isEmpty || !(removed[d] ?? []).isEmpty
        }
    }

    // MARK: Dependencies

    private let audio: AudioSystem
    private let clock: EngineClock
    private let store: StateStore
    public weak var delegate: EngineDelegate?

    // MARK: State

    public private(set) var state = PersistedState()
    public private(set) var lastAction: ActionRecord?
    public private(set) var history: [ActionRecord] = []
    public private(set) var isSessionActive = true
    public private(set) var isStarted = false
    /// True when storage was missing or unreadable at launch and lists were seeded.
    public private(set) var didSeedOnLaunch = false

    private var manualPicks: [Direction: String] = [:]
    private var devicesByUID: [String: AudioDevice] = [:]
    private var present: [Direction: Set<String>] = [.input: [], .output: []]
    private var usable: [Direction: Set<String>] = [.input: [], .output: []]
    /// Last default we observed or wrote ourselves. A default-changed event
    /// that matches it is our own echo and is ignored (F7).
    private var lastKnownDefault: [Direction: String] = [:]
    private var lastTopologyChange: [Direction: Date] = [:]
    private var lastWake: Date?
    /// Device macOS switched to, awaiting correction at the next evaluation.
    private var pendingCorrection: [Direction: String] = [:]
    private var lastResortEpisode: [Direction: Bool] = [:]
    private var loop: [Direction: LoopState] = [.input: LoopState(), .output: LoopState()]
    private var settleTask: Cancellable?
    private var settleDeadline: Date?
    private var nextActionID = 1

    public init(audio: AudioSystem, clock: EngineClock, store: StateStore) {
        self.audio = audio
        self.clock = clock
        self.store = store
    }

    // MARK: - Read-only views

    public var settings: PrioSettings { state.settings }

    public func list(_ d: Direction) -> RankedList { state.list(d) }

    public func manualPick(_ d: Direction) -> String? { manualPicks[d] }

    public func isLoopProtectionActive(_ d: Direction) -> Bool { loop[d]?.stopped ?? false }

    public func currentDefault(_ d: Direction) -> String? { audio.defaultDevice(d) }

    public func isConnected(_ uid: String, _ d: Direction) -> Bool { present[d]?.contains(uid) ?? false }

    public func isUsable(_ uid: String, _ d: Direction) -> Bool { usable[d]?.contains(uid) ?? false }

    public var isSettling: Bool { settleDeadline != nil }

    /// What Prio would select right now (F3).
    public func target(_ d: Direction) -> Target? {
        TargetSelector.select(list: state.list(d), connected: usable[d] ?? [], manualPick: manualPicks[d])
    }

    /// Undo is offered only for the latest action, only while the device it
    /// would restore is still connected (F13).
    public var canUndo: Bool {
        guard let a = lastAction, let u = a.undoUID else { return false }
        return usable[a.direction]?.contains(u) ?? false
    }

    public func rows(_ d: Direction) -> [DeviceRow] {
        let list = state.list(d)
        let names = list.displayNames()
        let def = audio.defaultDevice(d)
        return list.entries.enumerated().map { i, e in
            DeviceRow(
                uid: e.uid,
                name: e.name,
                displayName: names[e.uid] ?? e.name,
                transport: e.transport,
                direction: d,
                rank: i + 1,
                isConnected: present[d]?.contains(e.uid) ?? false,
                isUsable: usable[d]?.contains(e.uid) ?? false,
                isDefault: def == e.uid,
                isAvoided: e.avoided,
                isManualPick: manualPicks[d] == e.uid,
                isHeadphoneLike: d == .output && HeadphoneClassifier.isHeadphoneLike(name: e.name, transport: e.transport)
            )
        }
    }

    // MARK: - Lifecycle

    /// F2 seeding / loading, then F12 launch evaluation after 1 s.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        let devices = audio.devices()
        if let loaded = PersistedState.decode(store.load()) {
            state = loaded
            didSeedOnLaunch = false
            snapshot(devices, learn: true)
            // F6: a stored manual pick survives relaunch only if still connected.
            for d in Direction.allCases {
                if let uid = loaded.manualPicks[d.rawValue], usable[d]?.contains(uid) == true, state.settings.automaticSwitching {
                    manualPicks[d] = uid
                }
            }
        } else {
            let settings = state.settings
            state = PersistedState()
            state.settings = settings
            didSeedOnLaunch = true
            seed(devices)
            snapshot(devices, learn: false)
        }
        for d in Direction.allCases {
            lastKnownDefault[d] = audio.defaultDevice(d)
        }
        save()
        changed()
        scheduleSettle(Timing.settleLaunch)
    }

    /// F2: current default first, then the rest in OS order.
    private func seed(_ devices: [AudioDevice]) {
        for d in Direction.allCases {
            var list = RankedList()
            let eligible = devices.filter { $0.isEligible(for: d) }
            if let def = audio.defaultDevice(d), let dev = eligible.first(where: { $0.uid == def }) {
                list.append(RankedEntry(uid: dev.uid, name: dev.name, transport: dev.transport))
            }
            for dev in eligible {
                list.append(RankedEntry(uid: dev.uid, name: dev.name, transport: dev.transport))
            }
            state.setList(list, d)
        }
    }

    /// Update the device snapshot. Returns what changed.
    @discardableResult
    private func snapshot(_ devices: [AudioDevice], learn: Bool) -> TopologyChange {
        var change = TopologyChange()
        let oldByUID = devicesByUID
        devicesByUID = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        var listsChanged = false
        for d in Direction.allCases {
            let newPresent = Set(devices.filter { $0.isEligible(for: d) }.map(\.uid))
            let newUsable = Set(devices.filter { $0.isUsable(for: d) }.map(\.uid))
            let oldUsable = usable[d] ?? []
            let added = newUsable.subtracting(oldUsable)
            let removed = oldUsable.subtracting(newUsable)
            change.added[d] = added
            change.removed[d] = removed
            if newPresent != (present[d] ?? []) { change.presenceChanged.insert(d) }
            for uid in added.union(removed).union(newPresent.symmetricDifference(present[d] ?? [])) {
                let t = devicesByUID[uid]?.transport ?? oldByUID[uid]?.transport ?? state.list(d).entry(uid)?.transport
                if t == .bluetooth { change.involvesBluetooth = true }
            }
            present[d] = newPresent
            usable[d] = newUsable

            var list = state.list(d)
            let before = list
            for dev in devices where dev.isEligible(for: d) {
                if list.contains(dev.uid) {
                    list.refresh(from: dev)
                } else if learn {
                    let entry = RankedEntry(uid: dev.uid, name: dev.name, transport: dev.transport)
                    if d == .output && HeadphoneClassifier.isHeadphoneLike(dev) {
                        list.insertAtTop(entry)
                    } else {
                        list.append(entry)
                    }
                }
            }
            if list != before {
                state.setList(list, d)
                listsChanged = true
            }
        }
        if listsChanged { save() }
        return change
    }

    // MARK: - OS events

    /// Device list or device liveness changed.
    public func devicesDidChange() {
        guard isStarted else { return }
        // While the session is inactive Prio does nothing; the diff is applied
        // on reactivation instead (F12).
        guard isSessionActive else { return }
        let change = snapshot(audio.devices(), learn: true)
        guard !change.isEmpty else {
            changed()
            return
        }
        let now = clock.now
        for d in Direction.allCases where change.touches(d) {
            lastTopologyChange[d] = now
        }
        // F9: the stop lifts after 30 s without attempts plus a connect/disconnect.
        for d in Direction.allCases {
            if var l = loop[d], l.stopped {
                if let last = l.lastAttempt, now.timeIntervalSince(last) >= Timing.loopWindow {
                    l = LoopState()
                    loop[d] = l
                }
            }
        }
        endManualPicksIfNeeded(change)
        scheduleSettle(change.involvesBluetooth ? Timing.settleBluetooth : Timing.settleWired)
        changed()
    }

    /// F6: a pick ends when its device disconnects or a higher-ranked device connects.
    private func endManualPicksIfNeeded(_ change: TopologyChange) {
        var picksChanged = false
        for d in Direction.allCases {
            guard let pick = manualPicks[d] else { continue }
            let list = state.list(d)
            if change.removed[d]?.contains(pick) == true || !(usable[d]?.contains(pick) ?? false) {
                manualPicks[d] = nil
                picksChanged = true
                continue
            }
            guard let pickIndex = list.index(of: pick) else { continue }
            let higherArrived = (change.added[d] ?? []).contains { uid in
                (list.index(of: uid) ?? Int.max) < pickIndex
            }
            if higherArrived {
                manualPicks[d] = nil
                picksChanged = true
            }
        }
        if picksChanged { save() }
    }

    /// The system default for a direction changed (by anyone, including Prio).
    public func defaultDidChange(_ d: Direction) {
        guard isStarted, isSessionActive else { return }
        // The default-changed callback may arrive before the device-list one.
        devicesDidChange()
        let actual = audio.defaultDevice(d)
        let previous = lastKnownDefault[d]
        if actual == previous { return } // our own write's echo, or no change
        lastKnownDefault[d] = actual
        changed()
        guard settings.automaticSwitching, let actual else { return }
        guard let tgt = target(d) else { return }
        // macOS had to pick something because the previous default went away:
        // that is a plain fallback, handled as a switch rather than a correction.
        let forcedFallback = previous.map { !(usable[d]?.contains($0) ?? false) } ?? true
        if tgt.uid == actual || forcedFallback {
            pendingCorrection[d] = nil
            if !isSettling { evaluate(d) }
            return
        }
        if attributeToMacOS(d) || !settings.respectsExternalChanges(d) {
            // F7 rule 1 (or input with "respect" off): correct it.
            if loop[d]?.stopped == true { return } // F9: left alone
            pendingCorrection[d] = actual
            if !isSettling { evaluate(d) }
        } else {
            // F7 rule 2: the user chose it; it becomes the manual pick.
            pendingCorrection[d] = nil
            manualPicks[d] = actual
            if tgt.isLastResort == false { lastResortEpisode[d] = false }
            save()
            changed()
        }
    }

    /// F7 rule 1 attribution window, inclusive of the boundary.
    private func attributeToMacOS(_ d: Direction) -> Bool {
        let now = clock.now
        if let t = lastTopologyChange[d], now.timeIntervalSince(t) <= Timing.topologyAttribution { return true }
        if let w = lastWake, now.timeIntervalSince(w) <= Timing.wakeAttribution { return true }
        return false
    }

    public func systemWillSleep() {
        cancelSettle()
        pendingCorrection = [:]
    }

    /// F8: wait 2 s after wake, then evaluate.
    public func systemDidWake() {
        guard isStarted else { return }
        lastWake = clock.now
        guard isSessionActive else { return }
        scheduleSettle(Timing.settleWake)
    }

    public func sessionDidResignActive() {
        isSessionActive = false
        cancelSettle()
        pendingCorrection = [:]
        changed()
    }

    /// F12: clear last action, clear loop protection, re-evaluate.
    public func sessionDidBecomeActive() {
        guard isStarted else {
            isSessionActive = true
            return
        }
        guard !isSessionActive else { return }
        isSessionActive = true
        lastAction = nil
        resetLoopProtection()
        let change = snapshot(audio.devices(), learn: true)
        endManualPicksIfNeeded(change)
        for d in Direction.allCases {
            lastKnownDefault[d] = audio.defaultDevice(d)
        }
        evaluateAll()
        changed()
    }

    // MARK: - Settling

    private func scheduleSettle(_ delay: TimeInterval) {
        let now = clock.now
        let deadline = now.addingTimeInterval(delay)
        // A new event restarts the wait, but never shortens a longer pending one.
        if let existing = settleDeadline, existing >= deadline { return }
        settleTask?.cancel()
        settleDeadline = deadline
        settleTask = clock.schedule(after: delay) { [weak self] in
            self?.settleFired()
        }
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        settleDeadline = nil
    }

    private func settleFired() {
        settleTask = nil
        settleDeadline = nil
        evaluateAll()
    }

    // MARK: - Evaluation

    private func evaluateAll() {
        for d in Direction.allCases { evaluate(d) }
    }

    /// Make the system default equal to the target (F4), classifying the
    /// action as switch, correction or last resort.
    private func evaluate(_ d: Direction) {
        let macOSChoice = pendingCorrection.removeValue(forKey: d)
        guard isSessionActive, settings.automaticSwitching else { return }
        if let p = manualPicks[d], !(usable[d]?.contains(p) ?? false) {
            manualPicks[d] = nil
            save()
        }
        guard let tgt = target(d) else { return }
        if !tgt.isLastResort { lastResortEpisode[d] = false }
        let current = audio.defaultDevice(d)
        lastKnownDefault[d] = current
        if current == tgt.uid {
            if tgt.isLastResort && lastResortEpisode[d] != true {
                // F5: macOS already put the avoided device there; still tell the user once.
                lastResortEpisode[d] = true
                let a = record(.lastResort, d, from: nil, to: tgt.uid, undo: nil)
                post(.lastResort, d, a)
            }
            changed()
            return
        }
        let kind: ActionRecord.Kind
        if macOSChoice != nil && loop[d]?.stopped != true {
            kind = .corrected
        } else if tgt.isLastResort {
            kind = .lastResort
        } else {
            kind = .switched
        }
        perform(d, to: tgt.uid, kind: kind, from: current)
    }

    /// Write the default, verify it (F10), record and notify.
    private func perform(_ d: Direction, to uid: String, kind: ActionRecord.Kind, from: String?) {
        guard write(d, uid) else {
            fail(d, uid, from: from)
            return
        }
        let a = record(kind, d, from: from, to: uid, undo: from)
        switch kind {
        case .corrected:
            post(.correction, d, a, undo: true)
            registerAttempt(d)
        case .lastResort:
            if lastResortEpisode[d] != true {
                lastResortEpisode[d] = true
                post(.lastResort, d, a)
            }
        case .switched:
            if settings.notifyOnEverySwitch { post(.switched, d, a) }
        default:
            break
        }
        save()
        changed()
    }

    /// Set the default and read it back. Tracks the write so its echo is ignored.
    private func write(_ d: Direction, _ uid: String) -> Bool {
        lastKnownDefault[d] = uid // set before the call: the echo may arrive re-entrantly
        audio.setDefaultDevice(d, uid: uid)
        let actual = audio.defaultDevice(d)
        lastKnownDefault[d] = actual
        return actual == uid
    }

    private func fail(_ d: Direction, _ uid: String, from: String?) {
        let a = record(.failed, d, from: from, to: uid, undo: nil)
        post(.failure, d, a)
        registerAttempt(d)
        save()
        changed()
    }

    /// F9: count corrections and failed attempts; stop after 3 within 30 s.
    private func registerAttempt(_ d: Direction) {
        let now = clock.now
        var l = loop[d] ?? LoopState()
        l.attempts = l.attempts.filter { now.timeIntervalSince($0) < Timing.loopWindow }
        l.attempts.append(now)
        l.lastAttempt = now
        if !l.stopped && l.attempts.count >= Timing.loopLimit {
            l.stopped = true
            loop[d] = l
            let a = record(.loopStopped, d, from: nil, to: nil, undo: nil, makeLatest: false)
            post(.loopProtection, d, a)
        } else {
            loop[d] = l
        }
    }

    private func resetLoopProtection() {
        loop = [.input: LoopState(), .output: LoopState()]
    }

    // MARK: - User actions

    /// F6: choose a device from the menu.
    public func pick(_ uid: String, _ d: Direction) {
        guard isStarted, usable[d]?.contains(uid) == true else { return }
        pendingCorrection[d] = nil
        let before = audio.defaultDevice(d)
        if settings.automaticSwitching {
            manualPicks[d] = uid
        }
        if before != uid {
            if write(d, uid) {
                record(.picked, d, from: before, to: uid, undo: nil)
            } else {
                manualPicks[d] = nil
                fail(d, uid, from: before)
                return
            }
        }
        save()
        changed()
    }

    /// F13: restore the device selected before the latest action and pin it.
    /// `actionID` (from a notification) must match the latest action.
    public func undo(actionID: Int? = nil) {
        guard canUndo, let a = lastAction, let uid = a.undoUID else { return }
        if let id = actionID, id != a.id { return }
        let d = a.direction
        pendingCorrection[d] = nil
        let before = audio.defaultDevice(d)
        if write(d, uid) {
            if settings.automaticSwitching { manualPicks[d] = uid }
            record(.undone, d, from: before, to: uid, undo: nil)
            save()
            changed()
        } else {
            fail(d, uid, from: before)
        }
    }

    // MARK: - Ranking edits (F17); each triggers re-evaluation (F4)

    public func move(_ d: Direction, fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = state.list(d)
        guard list.move(fromOffsets: source, toOffset: destination) else { return }
        commitEdit(list, d)
    }

    public func moveUp(_ uid: String, _ d: Direction) {
        var list = state.list(d)
        guard list.moveUp(uid) else { return }
        commitEdit(list, d)
    }

    public func moveDown(_ uid: String, _ d: Direction) {
        var list = state.list(d)
        guard list.moveDown(uid) else { return }
        commitEdit(list, d)
    }

    public func moveToTop(_ uid: String, _ d: Direction) {
        var list = state.list(d)
        guard list.moveToTop(uid) else { return }
        commitEdit(list, d)
    }

    /// F5: unchecking "Use automatically". Avoiding the manual pick clears it.
    public func setAvoided(_ uid: String, _ d: Direction, _ avoided: Bool) {
        var list = state.list(d)
        guard list.setAvoided(uid, avoided) else { return }
        if avoided && manualPicks[d] == uid { manualPicks[d] = nil }
        commitEdit(list, d)
    }

    /// F2: forget a disconnected device. Connected devices cannot be forgotten.
    public func forget(_ uid: String, _ d: Direction) {
        guard !(present[d]?.contains(uid) ?? false) else { return }
        var list = state.list(d)
        guard list.remove(uid) else { return }
        if manualPicks[d] == uid { manualPicks[d] = nil }
        state.setList(list, d)
        save()
        changed()
    }

    private func commitEdit(_ list: RankedList, _ d: Direction) {
        state.setList(list, d)
        save()
        evaluate(d)
        changed()
    }

    // MARK: - Settings

    /// F11: off = never change devices automatically. On = clear picks and
    /// loop protection, then re-evaluate immediately.
    public func setAutomaticSwitching(_ on: Bool) {
        guard state.settings.automaticSwitching != on else { return }
        state.settings.automaticSwitching = on
        manualPicks = [:]
        pendingCorrection = [:]
        lastResortEpisode = [:]
        resetLoopProtection()
        save()
        if on { evaluateAll() }
        changed()
    }

    /// Update any setting. Automatic switching is routed through
    /// `setAutomaticSwitching` so its side effects apply.
    public func updateSettings(_ mutate: (inout PrioSettings) -> Void) {
        var s = state.settings
        mutate(&s)
        let auto = s.automaticSwitching
        s.automaticSwitching = state.settings.automaticSwitching
        if s != state.settings {
            state.settings = s
            save()
            changed()
        }
        setAutomaticSwitching(auto)
    }

    // MARK: - Recording & notifying

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
        history.append(a)
        if history.count > Timing.historyLimit {
            history.removeFirst(history.count - Timing.historyLimit)
        }
        return a
    }

    private func name(of uid: String) -> String {
        devicesByUID[uid]?.name
            ?? state.inputList.entry(uid)?.name
            ?? state.outputList.entry(uid)?.name
            ?? uid
    }

    private func post(_ kind: PrioNotification.Kind, _ d: Direction, _ a: ActionRecord, undo: Bool = false) {
        guard settings.notificationsEnabled else { return }
        let body: String
        switch kind {
        case .lastResort:
            body = "Using \(a.toName ?? "an avoided device") for \(d.lowercaseLabel). It’s set to avoid, but nothing else is connected."
        case .loopProtection:
            body = "Stopped correcting \(d.lowercaseLabel). Another app or macOS keeps changing it."
        default:
            body = a.sentence
        }
        delegate?.engine(self, post: PrioNotification(
            kind: kind, direction: d, title: "", body: body, undoActionID: undo ? a.id : nil
        ))
    }

    private func save() {
        var picks: [String: String] = [:]
        for (d, uid) in manualPicks { picks[d.rawValue] = uid }
        state.manualPicks = picks
        store.save(state.encoded())
    }

    private func changed() {
        delegate?.engineDidChange(self)
    }

    // MARK: - Diagnostics support

    public struct LoopInfo: Equatable, Sendable {
        public var stopped: Bool
        public var recentAttempts: Int
    }

    public func loopInfo(_ d: Direction) -> LoopInfo {
        let l = loop[d] ?? LoopState()
        let now = clock.now
        return LoopInfo(stopped: l.stopped, recentAttempts: l.attempts.filter { now.timeIntervalSince($0) < Timing.loopWindow }.count)
    }

    public var now: Date { clock.now }
}

/// A ranked-list entry joined with live state, for the UI.
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

    public var id: String { uid }

    public enum Status: String, Sendable {
        case inUse = "In use"
        case connected = "Connected"
        case notConnected = "Not connected"
    }

    public var status: Status {
        if isDefault && isConnected { return .inUse }
        return isConnected ? .connected : .notConnected
    }

    /// VoiceOver summary, e.g. "AirPods, rank 2, connected, avoided".
    public var accessibilitySummary: String {
        var parts = [displayName, "rank \(rank)", status.rawValue.lowercased()]
        if isAvoided { parts.append("avoided") }
        if isManualPick { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}
