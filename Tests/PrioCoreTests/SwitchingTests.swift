import Foundation
import Testing
@testable import PrioCore

@MainActor
@Suite("F4 Automatic switching")
struct AutomaticSwitchingTests {
    @Test("F4: when the default already equals the target, Prio does nothing")
    func noOp() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "a")
        h.launch()
        #expect(h.audio.setCount() == 0)
        #expect(h.engine.lastAction == nil)
        #expect(h.delegate.notifications.isEmpty)
        h.audio.connect(Dev.speaker("c"))
        h.advance(1)
        #expect(h.audio.setCount() == 0)
        #expect(h.engine.lastAction == nil)
    }

    @Test("F4: launch switches to the target")
    func launchSwitch() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "b")
        h.launch()
        #expect(h.def(.output) == "a")
        #expect(h.engine.lastAction?.kind == .switched)
    }

    @Test("F4: a ranking edit switches; it updates the last action but does not notify")
    func rankingEdit() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "a")
        h.launch()
        h.engine.moveToTop("b", .output)
        #expect(h.def(.output) == "b")
        #expect(h.engine.lastAction?.kind == .switched)
        #expect(h.engine.lastAction?.sentence == "Switched output from a to b.")
        #expect(h.delegate.notifications.isEmpty)
    }

    @Test("F4/F14: \"Notify on every switch\" posts a notification for switches")
    func notifyEverySwitch() {
        var s = PrioSettings()
        s.notifyOnEverySwitch = true
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "a", settings: s)
        h.launch()
        h.engine.move(.output, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(h.def(.output) == "b")
        #expect(h.delegate.count(.switched) == 1)
        #expect(h.delegate.notifications.first?.body == "Switched output from a to b.")
    }

    @Test("F4: a higher-ranked device connecting is a switch, not a correction")
    func higherRankedConnects() {
        let h = Harness(inputList: [entry("usb"), entry("builtin-mic")], connected: [Dev.builtInMic], input: "builtin-mic")
        h.launch()
        h.audio.connect(Dev.mic("usb"))
        h.advance(0.5)
        #expect(h.def(.input) == "usb")
        #expect(h.engine.lastAction?.kind == .switched)
        #expect(h.delegate.notifications.isEmpty)
    }

    @Test("F4: disconnecting the current device falls back to the next-ranked one")
    func disconnectFallback() {
        let h = Harness(outputList: [entry("a"), entry("b"), entry("c")], connected: [Dev.speaker("c"), Dev.speaker("a"), Dev.speaker("b")], output: "a")
        h.launch()
        h.audio.disconnect("a") // fake macOS falls back to "c" (first in OS order)
        h.advance(0.5)
        #expect(h.def(.output) == "b")
    }
}

@MainActor
@Suite("F5 Avoided devices")
struct AvoidedTests {
    @Test("F5 AC: [A(avoided), B]; only A connected → A, one notification; B connects → B, no last-resort notification")
    func acceptance() {
        let a = Dev.mic("A")
        let b = Dev.mic("B")
        let h = Harness(inputList: [entry("A", avoided: true), entry("B")], connected: [a, b], input: "B")
        h.launch()
        h.audio.disconnect("B") // macOS moves to A by itself
        h.advance(0.5)
        #expect(h.def(.input) == "A")
        #expect(h.delegate.count(.lastResort) == 1)
        #expect(h.engine.lastAction?.kind == .lastResort)
        // More events during the same episode: still one notification.
        h.audio.connect(Dev.mic("Z"))
        h.engine.setAvoided("Z", .input, true)
        h.advance(1)
        h.engine.systemDidWake()
        h.advance(3)
        #expect(h.delegate.count(.lastResort) == 1)
        h.audio.connect(b)
        h.advance(0.5)
        #expect(h.def(.input) == "B")
        #expect(h.delegate.count(.lastResort) == 1)
        #expect(h.delegate.notifications.count == 1)
    }

    @Test("F5: Prio switches to the last resort itself when needed, with one notification")
    func lastResortSwitch() {
        let h = Harness(inputList: [entry("A", avoided: true), entry("B")], connected: [Dev.mic("A"), Dev.mic("B")], input: "B")
        h.launch()
        h.audio.macOSFallbackOnDisconnect = false
        h.audio.disconnect("B")
        h.advance(0.5)
        #expect(h.def(.input) == "A")
        #expect(h.delegate.count(.lastResort) == 1)
        #expect(h.engine.lastAction?.kind == .lastResort)
    }

    @Test("F5: a new episode notifies again after the previous one ended")
    func newEpisode() {
        let h = Harness(inputList: [entry("A", avoided: true), entry("B")], connected: [Dev.mic("A"), Dev.mic("B")], input: "B")
        h.launch()
        h.audio.disconnect("B")
        h.advance(0.5)
        h.audio.connect(Dev.mic("B"))
        h.advance(0.5)
        h.audio.disconnect("B")
        h.advance(0.5)
        #expect(h.delegate.count(.lastResort) == 2)
    }

    @Test("F5: the episode is tracked even with notifications off")
    func episodeWithoutNotifications() {
        var s = PrioSettings()
        s.notificationsEnabled = false
        let h = Harness(inputList: [entry("A", avoided: true), entry("B")], connected: [Dev.mic("A"), Dev.mic("B")], input: "B", settings: s)
        h.launch()
        h.audio.disconnect("B")
        h.advance(0.5)
        #expect(h.delegate.notifications.isEmpty)
        h.engine.updateSettings { $0.notificationsEnabled = true }
        h.engine.systemDidWake()
        h.advance(3)
        #expect(h.delegate.notifications.isEmpty)
    }

    @Test("F5: avoided devices are skipped while a non-avoided device is connected")
    func skipped() {
        let h = Harness(outputList: [entry("display", avoided: true), entry("spk")], connected: [Dev.speaker("display"), Dev.speaker("spk")], output: "display")
        h.launch()
        #expect(h.def(.output) == "spk")
        #expect(h.engine.lastAction?.kind == .switched)
        #expect(h.delegate.notifications.isEmpty)
    }

    @Test("F5: avoid is per direction (a headset's mic vs its speakers)")
    func perDirection() {
        let hs = Dev.headset("hs", "Headset", transport: .usb)
        let h = Harness(
            inputList: [entry("hs"), entry("builtin-mic")], outputList: [entry("hs"), entry("builtin-out")],
            connected: [hs, Dev.builtInMic, Dev.builtInSpeakers], input: "hs", output: "hs"
        )
        h.launch()
        h.engine.setAvoided("hs", .input, true)
        #expect(h.def(.input) == "builtin-mic")
        #expect(h.def(.output) == "hs")
        #expect(h.engine.list(.output).entry("hs")?.avoided == false)
    }

    @Test("F5: avoiding the current manual pick clears it")
    func avoidClearsPick() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "a")
        h.launch()
        h.engine.pick("b", .output)
        #expect(h.engine.manualPick(.output) == "b")
        h.engine.setAvoided("b", .output, true)
        #expect(h.engine.manualPick(.output) == nil)
        #expect(h.def(.output) == "a")
    }

    @Test("F5: notification copy never claims avoided devices are never used")
    func copy() {
        let h = Harness(inputList: [entry("A", avoided: true)], connected: [Dev.mic("A"), Dev.mic("B")], input: "B")
        h.launch()
        h.audio.disconnect("B")
        h.advance(1)
        let text = h.delegate.notifications.map(\.body).joined() + h.actions.map(\.sentence).joined()
        #expect(!text.isEmpty)
        #expect(!text.lowercased().contains("never"))
    }
}

@MainActor
@Suite("F6 Manual pick")
struct ManualPickTests {
    func makeABC() -> Harness {
        let h = Harness(inputList: [entry("A"), entry("B"), entry("C")], connected: [Dev.mic("B"), Dev.mic("C")], input: "B")
        h.launch()
        return h
    }

    @Test("F6 AC: pick C stays through unrelated events; A connects → A selected, pick cleared")
    func acHigherConnects() {
        let h = makeABC()
        h.engine.pick("C", .input)
        #expect(h.def(.input) == "C")
        #expect(h.engine.manualPick(.input) == "C")
        // Unrelated events.
        h.audio.connect(Dev.mic("D"))
        h.advance(1)
        h.engine.systemDidWake()
        h.advance(3)
        h.engine.moveDown("B", .input)
        h.engine.moveUp("B", .input)
        #expect(h.def(.input) == "C")
        #expect(h.engine.manualPick(.input) == "C")
        h.audio.connect(Dev.mic("A"))
        #expect(h.engine.manualPick(.input) == nil)
        h.advance(0.5)
        #expect(h.def(.input) == "A")
    }

    @Test("F6 AC: pick C; C disconnects → B selected, pick cleared")
    func acPickDisconnects() {
        let h = makeABC()
        h.engine.pick("C", .input)
        h.audio.macOSFallbackOnDisconnect = false
        h.audio.disconnect("C")
        #expect(h.engine.manualPick(.input) == nil)
        h.advance(0.5)
        #expect(h.def(.input) == "B")
    }

    @Test("F6: a higher-ranked device that was already connected does not end the pick")
    func alreadyConnectedHigher() {
        let h = makeABC()
        h.engine.pick("C", .input)
        h.audio.setAlive("B", true) // B stays; no topology change
        h.advance(1)
        #expect(h.def(.input) == "C")
        #expect(h.engine.manualPick(.input) == "C")
    }

    @Test("F6: a lower-ranked device connecting does not end the pick")
    func lowerConnects() {
        let h = makeABC()
        h.engine.pick("B", .input)
        h.audio.connect(Dev.mic("Z"))
        h.advance(1)
        #expect(h.engine.manualPick(.input) == "B")
    }

    @Test("F6: picking an avoided device selects it immediately")
    func pickAvoided() {
        let h = Harness(inputList: [entry("A"), entry("X", avoided: true)], connected: [Dev.mic("A"), Dev.mic("X")], input: "A")
        h.launch()
        h.engine.pick("X", .input)
        #expect(h.def(.input) == "X")
        h.audio.connect(Dev.mic("Q"))
        h.advance(1)
        #expect(h.def(.input) == "X")
        #expect(h.delegate.count(.lastResort) == 0)
    }

    @Test("F6: the pick survives relaunch while the device is connected")
    func survivesRelaunch() {
        let h = makeABC()
        h.engine.pick("C", .input)
        h.relaunch()
        #expect(h.engine.manualPick(.input) == "C")
        #expect(h.def(.input) == "C")
    }

    @Test("F6: the pick is dropped at launch if the device is gone")
    func droppedAtRelaunch() {
        let h = makeABC()
        h.engine.pick("C", .input)
        h.audio.deviceList.removeAll { $0.uid == "C" }
        h.audio.defaults[.input] = "B"
        h.relaunch()
        #expect(h.engine.manualPick(.input) == nil)
        h.audio.deviceList.append(Dev.mic("C"))
        h.engine.devicesDidChange()
        h.advance(1)
        #expect(h.def(.input) == "B")
    }

    @Test("F6/F11: turning automatic switching off and on clears manual picks")
    func toggleClears() {
        let h = makeABC()
        h.engine.pick("C", .input)
        h.engine.setAutomaticSwitching(false)
        h.engine.setAutomaticSwitching(true)
        #expect(h.engine.manualPick(.input) == nil)
        #expect(h.def(.input) == "B")
    }

    @Test("F6 vs F2: new headphones inserted at #1 count as higher-ranked and end an output pick")
    func newHeadphonesEndPick() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "a")
        h.launch()
        h.engine.pick("b", .output)
        h.audio.connect(AudioDevice(uid: "bt", name: "AirPods", transport: .bluetooth, hasOutput: true))
        #expect(h.engine.manualPick(.output) == nil)
        h.advance(2)
        #expect(h.def(.output) == "bt")
    }

    @Test("F6: a menu pick records the action and the menu badge flag")
    func pickRecorded() {
        let h = makeABC()
        h.engine.pick("C", .input)
        #expect(h.engine.lastAction?.kind == .picked)
        #expect(h.engine.rows(.input).first { $0.uid == "C" }?.isManualPick == true)
        #expect(h.engine.canUndo == false)
    }

    @Test("F6: picking a device that is not ready does nothing")
    func pickNotReady() {
        let h = Harness(inputList: [entry("A"), entry("bt")], connected: [Dev.mic("A"), Dev.headset("bt", "Headset", alive: false)], input: "A")
        h.launch()
        h.engine.pick("bt", .input)
        #expect(h.def(.input) == "A")
        #expect(h.engine.manualPick(.input) == nil)
    }
}
