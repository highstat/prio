import Foundation
import Testing
@testable import PrioCore

@MainActor
@Suite("F8 Settling")
struct SettlingTests {
    @Test("F8 AC: a Bluetooth device going connect/disconnect/connect within 1 s causes at most one switch")
    func bluetoothFlap() {
        let h = Harness(devices: [Dev.builtInSpeakers], output: "builtin-out")
        h.launch()
        let bt = AudioDevice(uid: "bt", name: "AirPods", transport: .bluetooth, hasOutput: true)
        h.audio.connect(bt)
        h.advance(0.3)
        h.audio.disconnect("bt")
        h.advance(0.3)
        h.audio.connect(bt)
        h.advance(0.3)
        #expect(h.audio.setCount() == 0)
        h.advance(5)
        #expect(h.audio.setCount() == 1)
        #expect(h.def(.output) == "bt")
        #expect(h.actions(.switched).count == 1)
    }

    @Test("F8: wired devices settle after 0.5 s")
    func wired() {
        let h = Harness(inputList: [entry("usb"), entry("builtin-mic")], connected: [Dev.builtInMic], input: "builtin-mic")
        h.launch()
        h.audio.connect(Dev.mic("usb"))
        h.advance(0.4)
        #expect(h.def(.input) == "builtin-mic")
        h.advance(0.1)
        #expect(h.def(.input) == "usb")
    }

    @Test("F8: Bluetooth events settle after 2.0 s")
    func bluetooth() {
        let h = Harness(inputList: [entry("bt"), entry("builtin-mic")], connected: [Dev.builtInMic], input: "builtin-mic")
        h.launch()
        h.audio.connect(Dev.headset("bt", "Headset"))
        h.advance(1.9)
        #expect(h.def(.input) == "builtin-mic")
        h.advance(0.1)
        #expect(h.def(.input) == "bt")
    }

    @Test("F8: a new event restarts the wait")
    func restart() {
        let h = Harness(inputList: [entry("a"), entry("b"), entry("builtin-mic")], connected: [Dev.builtInMic], input: "builtin-mic")
        h.launch()
        h.audio.connect(Dev.mic("b"))
        h.advance(0.4)
        h.audio.connect(Dev.mic("a"))
        h.advance(0.4)
        #expect(h.audio.setCount() == 0)
        h.advance(0.1)
        #expect(h.def(.input) == "a")
        #expect(h.audio.setCount() == 1)
    }

    @Test("F8: a wired event right after a Bluetooth event does not shorten the Bluetooth wait")
    func noShortening() {
        let h = Harness(inputList: [entry("bt"), entry("builtin-mic")], connected: [Dev.builtInMic], input: "builtin-mic")
        h.launch()
        h.audio.connect(Dev.headset("bt", "Headset"))
        h.advance(0.1)
        h.audio.connect(Dev.mic("usb"))
        h.advance(1.0)
        #expect(h.audio.setCount() == 0)
        h.advance(0.9)
        #expect(h.def(.input) == "bt")
    }

    @Test("F8: after wake, Prio waits 2.0 s before evaluating")
    func wake() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "a")
        h.launch()
        h.audio.echoMode = .none
        h.audio.defaults[.output] = "b" // changed while asleep, no event
        h.engine.systemDidWake()
        h.advance(1.9)
        #expect(h.def(.output) == "b")
        h.advance(0.1)
        #expect(h.def(.output) == "a")
    }

    @Test("F8: a Bluetooth device listed but not yet usable is not selected until it becomes usable")
    func notUsable() {
        let h = Harness(devices: [Dev.builtInSpeakers], output: "builtin-out")
        h.launch()
        var bt = AudioDevice(uid: "bt", name: "AirPods", transport: .bluetooth, hasOutput: true)
        bt.isAlive = false
        h.audio.connect(bt)
        #expect(h.order(.output) == ["bt", "builtin-out"])
        #expect(h.engine.rows(.output)[0].isConnected)
        h.advance(5)
        #expect(h.def(.output) == "builtin-out")
        h.audio.setAlive("bt", true)
        h.advance(2)
        #expect(h.def(.output) == "bt")
    }
}

@MainActor
@Suite("F9 Loop protection")
struct LoopProtectionTests {
    func make(settings: PrioSettings = PrioSettings()) -> Harness {
        let h = Harness(
            inputList: [entry("builtin-mic"), entry("usb-mic")],
            outputList: [entry("builtin-out"), entry("usb-spk")],
            connected: [Dev.builtInMic, Dev.mic("usb-mic"), Dev.builtInSpeakers, Dev.speaker("usb-spk")],
            input: "builtin-mic", output: "builtin-out", settings: settings
        )
        h.launch()
        return h
    }

    func flip(_ h: Harness, _ d: Direction = .input, times: Int, every: TimeInterval = 2.5) {
        let other = d == .input ? "usb-mic" : "usb-spk"
        for _ in 0..<times {
            h.audio.externalSet(d, other)
            h.advance(every)
        }
    }

    @Test("F9 AC: an app flips the input 4 times in 10 s → exactly 3 corrections, 1 loop notification, no 4th correction")
    func acceptance() {
        let h = make()
        flip(h, times: 4)
        #expect(h.actions(.corrected).count == 3)
        #expect(h.delegate.count(.loopProtection) == 1)
        #expect(h.delegate.count(.correction) == 3)
        #expect(h.def(.input) == "usb-mic") // 4th change left alone
        #expect(h.engine.isLoopProtectionActive(.input))
        #expect(!h.engine.isLoopProtectionActive(.output))
    }

    @Test("F9: output loop (respect output off)")
    func outputLoop() {
        var s = PrioSettings()
        s.respectOutputChanges = false
        let h = make(settings: s)
        flip(h, .output, times: 5)
        #expect(h.actions(.corrected).count == 3)
        #expect(h.delegate.count(.loopProtection) == 1)
    }

    @Test("F9: further flips while stopped post no second loop notification")
    func noSecondNotification() {
        let h = make()
        flip(h, times: 10, every: 1)
        #expect(h.actions(.corrected).count == 3)
        #expect(h.delegate.count(.loopProtection) == 1)
    }

    @Test("F9: corrections spread over more than 30 s do not trigger it")
    func spreadOut() {
        let h = make()
        flip(h, times: 5, every: 16)
        #expect(h.actions(.corrected).count == 5)
        #expect(h.delegate.count(.loopProtection) == 0)
    }

    @Test("F9: while stopped, ranking edits and menu picks still work")
    func editsStillWork() {
        let h = make()
        flip(h, times: 4, every: 1)
        #expect(h.def(.input) == "usb-mic")
        h.engine.moveToTop("usb-mic", .input)
        h.engine.moveToTop("builtin-mic", .input)
        #expect(h.def(.input) == "builtin-mic")
        h.engine.pick("usb-mic", .input)
        #expect(h.def(.input) == "usb-mic")
    }

    @Test("F9: a connect 29 s after the last attempt does not lift the stop; one at 31 s does")
    func liftTiming() {
        let h = make()
        flip(h, times: 3, every: 1) // last correction at t≈2
        #expect(h.engine.isLoopProtectionActive(.input))
        h.advance(28) // 29 s after the last attempt
        h.audio.connect(Dev.speaker("x1"))
        #expect(h.engine.isLoopProtectionActive(.input))
        h.advance(2) // 31 s
        h.audio.connect(Dev.speaker("x2"))
        #expect(!h.engine.isLoopProtectionActive(.input))
        h.advance(5)
        h.audio.externalSet(.input, "usb-mic")
        #expect(h.def(.input) == "builtin-mic")
    }

    @Test("F9: toggling automatic switching off and on lifts the stop")
    func liftByToggle() {
        let h = make()
        flip(h, times: 3, every: 1)
        h.engine.setAutomaticSwitching(false)
        h.engine.setAutomaticSwitching(true)
        #expect(!h.engine.isLoopProtectionActive(.input))
    }

    @Test("F9: session reactivation lifts the stop")
    func liftBySession() {
        let h = make()
        flip(h, times: 3, every: 1)
        h.engine.sessionDidResignActive()
        h.engine.sessionDidBecomeActive()
        #expect(!h.engine.isLoopProtectionActive(.input))
    }
}

@MainActor
@Suite("F10 Failure detection")
struct FailureTests {
    @Test("F10: a refused switch is reported as a failure, not a success, and notifies")
    func refused() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "b")
        h.audio.refuse = ["a"]
        h.launch()
        #expect(h.def(.output) == "b")
        #expect(h.engine.lastAction?.kind == .failed)
        #expect(h.engine.lastAction?.sentence == "Couldn’t switch output to a.")
        #expect(h.actions(.switched).isEmpty)
        #expect(h.delegate.count(.failure) == 1)
        #expect(h.engine.canUndo == false)
    }

    @Test("F10: verification reads the default back even if the OS call claims success")
    func silentNoop() {
        final class LyingAudio: AudioSystem {
            var d: [Direction: String] = [.output: "b"]
            let devs = [Dev.speaker("a"), Dev.speaker("b")]
            func devices() -> [AudioDevice] { devs }
            func defaultDevice(_ direction: Direction) -> String? { d[direction] }
            func setDefaultDevice(_ direction: Direction, uid: String) -> Bool { true }
        }
        var s = PersistedState()
        s.outputList = RankedList([entry("a"), entry("b")])
        let clock = TestClock()
        let e = Engine(audio: LyingAudio(), clock: clock, store: MemoryStore(s.encoded()))
        e.start()
        clock.advance(by: 1)
        #expect(e.lastAction?.kind == .failed)
    }

    @Test("F10: failed attempts count toward loop protection")
    func countsTowardLoop() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "b")
        h.audio.refuse = ["a"]
        h.launch() // failure 1
        h.engine.systemDidWake()
        h.advance(2) // failure 2
        h.engine.systemDidWake()
        h.advance(2) // failure 3 → stop
        #expect(h.actions(.failed).count == 3)
        #expect(h.engine.isLoopProtectionActive(.output))
        #expect(h.delegate.count(.loopProtection) == 1)
    }

    @Test("F10: a failed menu pick is reported and does not leave a pin behind")
    func failedPick() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "a")
        h.launch()
        h.audio.refuse = ["b"]
        h.engine.pick("b", .output)
        #expect(h.engine.lastAction?.kind == .failed)
        #expect(h.engine.manualPick(.output) == nil)
    }
}
