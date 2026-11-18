import Foundation
import Testing
@testable import PrioCore

@MainActor
@Suite("F7 Changes made outside Prio")
struct ExternalChangeTests {
    /// Input: built-in mic ranked first. Output: speakers first.
    func standard(settings: PrioSettings = PrioSettings()) -> Harness {
        let h = Harness(
            inputList: [entry("builtin-mic"), entry("usb-mic")],
            outputList: [entry("builtin-out"), entry("usb-spk")],
            connected: [Dev.builtInMic, Dev.mic("usb-mic"), Dev.builtInSpeakers, Dev.speaker("usb-spk")],
            input: "builtin-mic", output: "builtin-out", settings: settings
        )
        h.launch()
        return h
    }

    @Test("F7 headline: Bluetooth headset connects, macOS grabs its mic → corrected after settling, with Undo")
    func headsetGrabsInput() {
        let h = standard()
        let hs = Dev.headset("hs", "AirPods Pro")
        h.audio.connect(hs, macOSSelects: [.input, .output])
        #expect(h.def(.input) == "hs")
        h.advance(1.9)
        #expect(h.def(.input) == "hs") // still settling (Bluetooth: 2 s)
        h.advance(0.1)
        #expect(h.def(.input) == "builtin-mic")
        #expect(h.def(.output) == "hs") // output target is the headset (#1): nothing to do
        let corrections = h.actions(.corrected)
        #expect(corrections.count == 1)
        #expect(corrections.first?.direction == .input)
        #expect(h.delegate.count(.correction) == 1)
        let n = h.delegate.notifications.first { $0.kind == .correction }
        #expect(n?.undoActionID == h.engine.lastAction?.id)
        #expect(n?.body == "macOS picked AirPods Pro for input. Prio kept MacBook Pro Microphone.")
        #expect(h.engine.canUndo)
        #expect(h.delegate.notifications.count == 1)
    }

    @Test("F7 headline: when macOS leaves the output alone, Prio switches it to the new headset without a notification")
    func headsetOutputSwitch() {
        let h = standard()
        h.audio.connect(Dev.headset("hs", "AirPods Pro"), macOSSelects: [.input])
        h.advance(2)
        #expect(h.def(.output) == "hs")
        #expect(h.actions(.switched).count == 1)
        #expect(h.delegate.count(.switched) == 0)
        #expect(h.delegate.count(.correction) == 1)
    }

    @Test("F7 rule 1: wired connect, then macOS changes the input 1 s later → correction")
    func ruleOneAfterSettle() {
        let h = standard()
        h.audio.connect(Dev.mic("cam", "Webcam"))
        h.advance(1)
        h.audio.externalSet(.input, "cam")
        #expect(h.def(.input) == "builtin-mic")
        #expect(h.actions(.corrected).count == 1)
        #expect(h.delegate.count(.correction) == 1)
    }

    @Test("F7 rule 1 applies to output too, even with \"respect output\" on")
    func ruleOneOutput() {
        let h = standard()
        h.audio.connect(Dev.speaker("hdmi", "LG Monitor", transport: .hdmiDisplayPort))
        h.advance(1)
        h.audio.externalSet(.output, "hdmi")
        #expect(h.def(.output) == "builtin-out")
        #expect(h.engine.manualPick(.output) == nil)
        #expect(h.delegate.count(.correction) == 1)
    }

    @Test("F7 rule 1: the 3 s topology window is inclusive (3.0 s → macOS)")
    func topologyBoundaryInside() {
        let h = standard()
        h.audio.connect(Dev.speaker("x"))
        h.advance(3.0)
        h.audio.externalSet(.output, "usb-spk")
        #expect(h.def(.output) == "builtin-out")
        #expect(h.actions(.corrected).count == 1)
    }

    @Test("F7 rule 2: just outside the 3 s window (3.1 s) → attributed to the user")
    func topologyBoundaryOutside() {
        let h = standard()
        h.audio.connect(Dev.speaker("x"))
        h.advance(3.1)
        h.audio.externalSet(.output, "usb-spk")
        #expect(h.def(.output) == "usb-spk")
        #expect(h.engine.manualPick(.output) == "usb-spk")
        #expect(h.actions(.corrected).isEmpty)
    }

    @Test("F7 rule 1: within 5 s of wake → macOS (5.0 s inclusive)")
    func wakeBoundaryInside() {
        let h = standard()
        h.engine.systemDidWake()
        h.advance(5.0)
        h.audio.externalSet(.output, "usb-spk")
        #expect(h.def(.output) == "builtin-out")
        #expect(h.delegate.count(.correction) == 1)
    }

    @Test("F7 rule 2: 5.1 s after wake → user")
    func wakeBoundaryOutside() {
        let h = standard()
        h.engine.systemDidWake()
        h.advance(5.1)
        h.audio.externalSet(.output, "usb-spk")
        #expect(h.def(.output) == "usb-spk")
        #expect(h.engine.manualPick(.output) == "usb-spk")
    }

    @Test("F7 rule 1: macOS change during the wake settle is corrected when the settle ends")
    func wakeDuringSettle() {
        let h = standard()
        h.engine.systemDidWake()
        h.advance(0.5)
        h.audio.externalSet(.input, "usb-mic")
        #expect(h.def(.input) == "usb-mic")
        h.advance(1.5)
        #expect(h.def(.input) == "builtin-mic")
        #expect(h.actions(.corrected).count == 1)
    }

    @Test("F7 rule 2 output, respect on (default): becomes the manual pick, no notification")
    func outputRespected() {
        let h = standard()
        h.audio.externalSet(.output, "usb-spk")
        #expect(h.def(.output) == "usb-spk")
        #expect(h.engine.manualPick(.output) == "usb-spk")
        #expect(h.delegate.notifications.isEmpty)
        #expect(h.engine.lastAction == nil)
        // It now behaves like a manual pick.
        h.audio.connect(Dev.speaker("z"))
        h.advance(1)
        #expect(h.def(.output) == "usb-spk")
    }

    @Test("F7 rule 2 output, respect off: corrected")
    func outputNotRespected() {
        var s = PrioSettings()
        s.respectOutputChanges = false
        let h = standard(settings: s)
        h.audio.externalSet(.output, "usb-spk")
        #expect(h.def(.output) == "builtin-out")
        #expect(h.delegate.count(.correction) == 1)
    }

    @Test("F7 rule 2 input, respect off (default): corrected")
    func inputNotRespected() {
        let h = standard()
        #expect(PrioSettings().respectInputChanges == false)
        h.audio.externalSet(.input, "usb-mic")
        #expect(h.def(.input) == "builtin-mic")
        #expect(h.engine.manualPick(.input) == nil)
        #expect(h.delegate.count(.correction) == 1)
        #expect(h.engine.lastAction?.kind == .corrected)
        #expect(h.engine.lastAction?.undoUID == "usb-mic")
    }

    @Test("F7 rule 2 input, respect on: becomes the manual pick")
    func inputRespected() {
        var s = PrioSettings()
        s.respectInputChanges = true
        let h = standard(settings: s)
        h.audio.externalSet(.input, "usb-mic")
        #expect(h.def(.input) == "usb-mic")
        #expect(h.engine.manualPick(.input) == "usb-mic")
        #expect(h.delegate.notifications.isEmpty)
    }

    @Test("F7: attribution is per direction (output topology change does not make an input change macOS's)")
    func perDirectionAttribution() {
        var s = PrioSettings()
        s.respectInputChanges = true
        let h = standard(settings: s)
        h.audio.connect(Dev.speaker("new-spk"))
        h.advance(1)
        h.audio.externalSet(.input, "usb-mic")
        #expect(h.def(.input) == "usb-mic")
        #expect(h.engine.manualPick(.input) == "usb-mic")
        #expect(h.actions(.corrected).isEmpty)
    }

    @Test("F7: an external change to the target device itself is not a correction")
    func changeToTarget() {
        let h = standard()
        h.engine.pick("usb-mic", .input)
        h.audio.externalSet(.input, "usb-mic") // no-op change
        h.audio.externalSet(.input, "builtin-mic")
        #expect(h.def(.input) == "usb-mic") // corrected back to manual pick
        #expect(h.actions(.corrected).count == 1)
    }

    @Test("F7: echoes of Prio's own writes (evaluation, ranking edit, menu pick, undo) are ignored", arguments: [FakeAudioSystem.EchoMode.async, .reentrant])
    func ownWritesIgnored(mode: FakeAudioSystem.EchoMode) {
        var s = PrioSettings()
        s.respectInputChanges = true // an echo mistaken for a user change would create a pick
        let h = Harness(
            inputList: [entry("a"), entry("b"), entry("c")],
            connected: [Dev.mic("a"), Dev.mic("b"), Dev.mic("c")],
            input: "c", settings: s
        )
        h.audio.echoMode = mode
        h.launch() // evaluation write: c → a
        #expect(h.def(.input) == "a")
        h.engine.moveToTop("b", .input) // ranking write: a → b
        h.audio.flush()
        h.engine.pick("c", .input) // menu write
        h.audio.flush()
        h.engine.setAutomaticSwitching(false)
        h.engine.setAutomaticSwitching(true) // write: c → b
        h.audio.flush()
        h.audio.connect(Dev.mic("d"))
        h.advance(4)
        h.audio.externalSet(.input, "d") // user change → manual pick d
        #expect(h.engine.manualPick(.input) == "d")
        // Undo write.
        h.engine.setAutomaticSwitching(false)
        h.engine.setAutomaticSwitching(true)
        h.audio.flush()
        #expect(h.def(.input) == "b")
        h.engine.undo() // b → d
        h.audio.flush()
        #expect(h.def(.input) == "d")
        #expect(h.engine.manualPick(.input) == "d")
        #expect(h.actions(.corrected).isEmpty)
        #expect(h.delegate.notifications.isEmpty)
    }

    @Test("F7: own-write echoes are ignored even when corrections would apply (respect input off)")
    func ownWritesNoCorrection() {
        let h = Harness(inputList: [entry("a"), entry("b")], connected: [Dev.mic("a"), Dev.mic("b")], input: "b")
        h.launch()
        h.engine.moveToTop("b", .input)
        h.audio.flush()
        h.engine.pick("a", .input)
        h.audio.flush()
        #expect(h.actions(.corrected).isEmpty)
        #expect(h.audio.setCount() == 3)
    }

    @Test("F7: default-changed arriving before the device-list change is still attributed to macOS")
    func eventOrdering() {
        let h = Harness(
            inputList: [entry("usb-mic"), entry("builtin-mic"), entry("cam")],
            connected: [Dev.mic("cam"), Dev.mic("usb-mic"), Dev.builtInMic],
            input: "usb-mic"
        )
        h.launch()
        h.audio.defaultEventFirst = true
        h.audio.disconnect("usb-mic") // macOS falls back to "cam" (first in OS order)
        #expect(h.def(.input) == "cam")
        h.advance(0.5)
        #expect(h.def(.input) == "builtin-mic")
        #expect(h.engine.manualPick(.input) == nil)
        // macOS had to fall back because the default vanished: a switch, not a correction.
        #expect(h.actions(.corrected).isEmpty)
        #expect(h.actions(.switched).count == 1)
    }

    @Test("F7: no action at all while automatic switching is off")
    func pausedIgnores() {
        let h = standard()
        h.engine.setAutomaticSwitching(false)
        h.audio.externalSet(.input, "usb-mic")
        h.advance(5)
        #expect(h.def(.input) == "usb-mic")
        #expect(h.engine.manualPick(.input) == nil)
        #expect(h.actions(.corrected).isEmpty)
    }
}
