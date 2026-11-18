import Foundation
import Testing
@testable import PrioCore

@MainActor
@Suite("Persistence (section 7)")
struct PersistenceTests {
    @Test("Lists, avoided flags, settings and pause state survive relaunch")
    func roundTrip() {
        let h = Harness(devices: [Dev.mic("m1"), Dev.mic("m2"), Dev.speaker("s1"), Dev.speaker("s2")], input: "m1", output: "s1")
        h.launch()
        h.engine.moveToTop("m2", .input)
        h.engine.setAvoided("s1", .output, true)
        h.engine.updateSettings {
            $0.notifyOnEverySwitch = true
            $0.respectInputChanges = true
        }
        h.engine.setAutomaticSwitching(false)
        h.relaunch()
        #expect(!h.engine.didSeedOnLaunch)
        #expect(h.order(.input) == ["m2", "m1"])
        #expect(h.engine.list(.output).entry("s1")?.avoided == true)
        #expect(h.engine.settings.notifyOnEverySwitch)
        #expect(h.engine.settings.respectInputChanges)
        #expect(!h.engine.settings.automaticSwitching)
    }

    @Test("Corrupt storage starts fresh with seeding, without crashing")
    func corrupt() {
        let h = Harness(devices: [Dev.mic("m1"), Dev.mic("m2")], input: "m2", storedData: Data("{not json".utf8))
        h.launch()
        #expect(h.engine.didSeedOnLaunch)
        #expect(h.order(.input) == ["m2", "m1"])
        #expect(PersistedState.decode(h.store.data) != nil)
    }

    @Test("Missing storage starts fresh with seeding")
    func missing() {
        let h = Harness(devices: [Dev.mic("m1")], input: "m1")
        h.launch()
        #expect(h.engine.didSeedOnLaunch)
        #expect(h.store.saveCount > 0)
    }

    @Test("Upgrade: missing keys take defaults, unknown keys and transports are tolerated")
    func upgrade() throws {
        let json = """
        {"inputList":{"entries":[{"uid":"x","name":"X","transport":"futureBus"},{"uid":"y"}]},
         "settings":{"automaticSwitching":false,"someFutureSetting":42},
         "anotherFutureKey":[1,2,3]}
        """
        let s = try #require(PersistedState.decode(Data(json.utf8)))
        #expect(s.inputList.uids == ["x", "y"])
        #expect(s.inputList.entries[0].transport == .other)
        #expect(s.inputList.entries[1].name == "y")
        #expect(s.inputList.entries[1].avoided == false)
        #expect(s.settings.automaticSwitching == false)
        #expect(s.settings.respectOutputChanges == true)
        #expect(s.settings.respectInputChanges == false)
        #expect(s.outputList.entries.isEmpty)
        #expect(s.version == PersistedState.currentVersion)
    }

    @Test("Default settings match the spec")
    func defaults() {
        let s = PrioSettings()
        #expect(s.automaticSwitching)
        #expect(s.notificationsEnabled)
        #expect(!s.notifyOnEverySwitch)
        #expect(s.respectOutputChanges)
        #expect(!s.respectInputChanges)
    }
}

@MainActor
@Suite("F19 Diagnostics")
struct DiagnosticsTests {
    let env = DiagnosticsEnvironment(appVersion: "1.0.0", osVersion: "13.6", architecture: "arm64")

    func make() -> Harness {
        let h = Harness(
            inputList: [RankedEntry(uid: "BT:AA-BB-CC-DD-EE-FF:input", name: "Misha’s AirPods", transport: .bluetooth),
                        RankedEntry(uid: "AppleUSBAudioEngine:Blue:Yeti:123", name: "Yeti Stereo Microphone", transport: .usb)],
            outputList: [RankedEntry(uid: "BT:AA-BB-CC-DD-EE-FF:output", name: "Misha’s AirPods", transport: .bluetooth, avoided: true),
                         RankedEntry(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn)],
            connected: [
                AudioDevice(uid: "AppleUSBAudioEngine:Blue:Yeti:123", name: "Yeti Stereo Microphone", transport: .usb, hasInput: true),
                AudioDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn, hasOutput: true),
                AudioDevice(uid: "BuiltInMic", name: "MacBook Pro Microphone", transport: .builtIn, hasInput: true),
            ],
            input: "BuiltInMic", output: "BuiltInSpeakerDevice"
        )
        h.launch()
        h.engine.pick("BuiltInMic", .input)
        h.engine.moveToTop("BuiltInMic", .input)
        return h
    }

    @Test("F19: names and device identifiers are replaced unless names are included")
    func anonymized() {
        let h = make()
        let text = Diagnostics.report(engine: h.engine, environment: env, includeNames: false)
        for leak in ["AirPods", "Yeti", "MacBook", "Misha", "AA-BB", "BuiltIn", "Apple", "Blue:"] {
            #expect(!text.contains(leak), "leaked \(leak)")
        }
        #expect(text.contains("Input 1"))
        #expect(text.contains("Output 2"))
    }

    @Test("F19: contents include versions, settings, lists, defaults, picks, loop state and actions")
    func contents() {
        let h = make()
        let text = Diagnostics.report(engine: h.engine, environment: env, includeNames: true)
        for needle in [
            "Prio version: 1.0.0", "macOS version: 13.6", "Architecture: arm64",
            "Automatic switching: on", "Respect input changes made outside Prio: off",
            "Input list", "Output list", "Bluetooth", "USB", "Built-in", "Not connected", "In use", "avoided",
            "Current default: MacBook Pro Speakers", "Manual pick: MacBook Pro Microphone",
            "Loop protection: off", "Recent actions", "You picked MacBook Pro Microphone for input.",
            "Yeti Stereo Microphone",
        ] {
            #expect(text.contains(needle), "missing \(needle)")
        }
        #expect(!text.contains("AA-BB"))
    }
}
