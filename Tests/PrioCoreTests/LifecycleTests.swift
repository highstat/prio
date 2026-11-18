import Foundation
import Testing
@testable import PrioCore

@MainActor
@Suite("F11 Pause")
struct PauseTests {
    func make() -> Harness {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("b")], output: "b")
        h.launch()
        return h
    }

    @Test("F11: when off, Prio never changes devices automatically")
    func off() {
        let h = make()
        h.engine.setAutomaticSwitching(false)
        h.audio.connect(Dev.speaker("a"))
        h.engine.systemDidWake()
        h.advance(10)
        #expect(h.def(.output) == "b")
        #expect(h.audio.setCount() == 0)
    }

    @Test("F11: menu picks still switch once while paused, without becoming a pin")
    func pickWhilePaused() {
        let h = make()
        h.audio.connect(Dev.speaker("a"))
        h.advance(1)
        h.engine.setAutomaticSwitching(false)
        h.engine.pick("b", .output)
        #expect(h.def(.output) == "b")
        #expect(h.engine.manualPick(.output) == nil)
    }

    @Test("F11: the state persists across relaunch")
    func persists() {
        let h = make()
        h.engine.setAutomaticSwitching(false)
        h.audio.connect(Dev.speaker("a"))
        h.relaunch()
        #expect(h.engine.settings.automaticSwitching == false)
        h.advance(5)
        #expect(h.def(.output) == "b")
    }

    @Test("F11: turning it back on re-evaluates immediately")
    func onEvaluates() {
        let h = make()
        h.engine.setAutomaticSwitching(false)
        h.audio.connect(Dev.speaker("a"))
        h.advance(1)
        #expect(h.def(.output) == "b")
        h.engine.setAutomaticSwitching(true)
        #expect(h.def(.output) == "a")
    }

    @Test("F11: updateSettings routes the toggle through the same side effects")
    func viaUpdateSettings() {
        let h = make()
        h.audio.connect(Dev.speaker("a"))
        h.advance(1)
        h.engine.pick("b", .output)
        h.engine.updateSettings { $0.automaticSwitching = false }
        h.engine.updateSettings { $0.automaticSwitching = true }
        #expect(h.engine.manualPick(.output) == nil)
        #expect(h.def(.output) == "a")
    }
}

@MainActor
@Suite("F12 Session, sleep and login")
struct SessionTests {
    @Test("F12: on launch both directions are evaluated after 1 s")
    func launchDelay() {
        let h = Harness(
            inputList: [entry("m1"), entry("m2")], outputList: [entry("s1"), entry("s2")],
            connected: [Dev.mic("m1"), Dev.mic("m2"), Dev.speaker("s1"), Dev.speaker("s2")],
            input: "m2", output: "s2"
        )
        h.launch(settle: false)
        h.advance(0.9)
        #expect(h.audio.setCount() == 0)
        h.advance(0.1)
        #expect(h.def(.input) == "m1")
        #expect(h.def(.output) == "s1")
    }

    @Test("F12: while the session is inactive, Prio does nothing")
    func inactive() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("b")], output: "b")
        h.launch()
        h.engine.sessionDidResignActive()
        h.audio.connect(Dev.speaker("a"))
        h.audio.externalSet(.output, "b")
        h.engine.systemDidWake()
        h.advance(10)
        #expect(h.def(.output) == "b")
        #expect(h.audio.setCount() == 0)
    }

    @Test("F12: on reactivation, last action and Undo are cleared and Prio re-evaluates")
    func reactivation() {
        let h = Harness(inputList: [entry("builtin-mic"), entry("usb-mic")], connected: [Dev.builtInMic, Dev.mic("usb-mic")], input: "builtin-mic")
        h.launch()
        h.audio.externalSet(.input, "usb-mic") // corrected → undo available
        #expect(h.engine.canUndo)
        h.engine.sessionDidResignActive()
        h.audio.externalSet(.input, "usb-mic") // ignored while inactive
        #expect(h.def(.input) == "usb-mic")
        h.engine.sessionDidBecomeActive()
        #expect(h.engine.lastAction?.kind == .switched)
        #expect(h.def(.input) == "builtin-mic")
        h.engine.sessionDidResignActive()
        h.engine.sessionDidBecomeActive()
        #expect(h.engine.lastAction == nil)
        #expect(!h.engine.canUndo)
    }

    @Test("F12: devices that changed while inactive are learned and applied on reactivation")
    func changesWhileInactive() {
        let h = Harness(inputList: [entry("A"), entry("B"), entry("C")], connected: [Dev.mic("B"), Dev.mic("C")], input: "B")
        h.launch()
        h.engine.pick("C", .input)
        h.engine.sessionDidResignActive()
        h.audio.connect(Dev.mic("A"))
        h.audio.connect(Dev.mic("N"))
        #expect(!h.engine.list(.input).contains("N"))
        h.engine.sessionDidBecomeActive()
        #expect(h.engine.list(.input).contains("N"))
        #expect(h.engine.manualPick(.input) == nil) // higher-ranked A arrived
        #expect(h.def(.input) == "A")
    }
}

@MainActor
@Suite("F13 Last action & Undo")
struct UndoTests {
    func corrected() -> Harness {
        let h = Harness(
            inputList: [entry("builtin-mic"), entry("usb-mic")],
            connected: [Dev.builtInMic, Dev.mic("usb-mic", "Yeti")],
            input: "builtin-mic"
        )
        h.launch()
        h.audio.externalSet(.input, "usb-mic")
        return h
    }

    @Test("F13: the last action names what macOS chose and what Prio kept, with a timestamp")
    func sentence() {
        let h = corrected()
        let a = h.engine.lastAction
        #expect(a?.sentence == "macOS picked Yeti for input. Prio kept MacBook Pro Microphone.")
        #expect(a?.date == h.clock.now)
    }

    @Test("F13: Undo restores the previous device and pins it so Prio does not revert it")
    func undoPins() {
        let h = corrected()
        h.engine.undo()
        #expect(h.def(.input) == "usb-mic")
        #expect(h.engine.manualPick(.input) == "usb-mic")
        #expect(h.engine.lastAction?.kind == .undone)
        #expect(h.engine.lastAction?.sentence == "Undone. Input is back on Yeti.")
        h.audio.connect(Dev.mic("other"))
        h.advance(5)
        #expect(h.def(.input) == "usb-mic")
    }

    @Test("F13: Undo disappears once used")
    func usedOnce() {
        let h = corrected()
        h.engine.undo()
        #expect(!h.engine.canUndo)
        let sets = h.audio.setCount()
        h.engine.undo()
        #expect(h.audio.setCount() == sets)
    }

    @Test("F13: Undo disappears when the device it would restore is gone")
    func deviceGone() {
        let h = corrected()
        h.audio.disconnect("usb-mic")
        #expect(!h.engine.canUndo)
        h.engine.undo()
        #expect(h.def(.input) == "builtin-mic")
    }

    @Test("F13: Undo applies only to the latest action (stale notification action IDs are ignored)")
    func latestOnly() {
        let h = corrected()
        let firstID = h.engine.lastAction!.id
        h.advance(40)
        h.audio.connect(Dev.mic("cam"))
        h.advance(1)
        h.audio.externalSet(.input, "cam") // second correction
        #expect(h.engine.lastAction!.id != firstID)
        h.engine.undo(actionID: firstID)
        #expect(h.def(.input) == "builtin-mic")
        h.engine.undo(actionID: h.engine.lastAction!.id)
        #expect(h.def(.input) == "cam")
    }

    @Test("F13: history keeps the last 20 actions")
    func historyLimit() {
        let h = Harness(outputList: [entry("a"), entry("b")], connected: [Dev.speaker("a"), Dev.speaker("b")], output: "a")
        h.launch()
        for _ in 0..<15 {
            h.engine.moveToTop("b", .output)
            h.engine.moveToTop("a", .output)
        }
        #expect(h.engine.history.count == 20)
    }
}

@MainActor
@Suite("F14 Notifications (engine side)")
struct NotificationTests {
    @Test("F14: one switch turns all notifications off; behaviour is unchanged")
    func allOff() {
        var s = PrioSettings()
        s.notificationsEnabled = false
        s.notifyOnEverySwitch = true
        let h = Harness(inputList: [entry("builtin-mic"), entry("usb-mic")], connected: [Dev.builtInMic, Dev.mic("usb-mic")], input: "builtin-mic", settings: s)
        h.launch()
        h.audio.externalSet(.input, "usb-mic")
        h.engine.moveToTop("usb-mic", .input)
        #expect(h.def(.input) == "usb-mic")
        #expect(h.actions(.corrected).count == 1)
        #expect(h.delegate.notifications.isEmpty)
    }

    @Test("F14: only corrections carry Undo; texts are one line and name devices")
    func shapes() {
        let h = Harness(inputList: [entry("builtin-mic"), entry("usb-mic")], connected: [Dev.builtInMic, Dev.mic("usb-mic", "Yeti")], input: "builtin-mic")
        h.audio.refuse = []
        h.launch()
        h.audio.externalSet(.input, "usb-mic")
        h.audio.refuse = ["usb-mic"]
        h.engine.moveToTop("usb-mic", .input)
        let correction = h.delegate.notifications.first { $0.kind == .correction }
        let failure = h.delegate.notifications.first { $0.kind == .failure }
        #expect(correction?.undoActionID != nil)
        #expect(failure?.undoActionID == nil)
        #expect(failure?.body == "Couldn’t switch input to Yeti.")
        for n in h.delegate.notifications {
            #expect(!n.body.contains("\n"))
        }
    }
}
