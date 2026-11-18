import Foundation
import Testing
@testable import PrioCore

@MainActor
@Suite("F1/F2 Device lists")
struct ListTests {
    @Test("F1 AC: moving a headset's input to #1 leaves its output position unchanged")
    func f1Independent() {
        let headset = Dev.headset("hs", "Jabra Evolve")
        let h = Harness(
            inputList: [entry("mic"), entry("hs")],
            outputList: [entry("spk"), entry("hs"), entry("tv")],
            connected: [Dev.mic("mic"), Dev.speaker("spk"), headset, Dev.speaker("tv")],
            input: "mic", output: "spk"
        )
        h.launch()
        h.engine.moveToTop("hs", .input)
        #expect(h.order(.input) == ["hs", "mic"])
        #expect(h.order(.output) == ["spk", "hs", "tv"])
    }

    @Test("F1: speakers and headphones share the single output list")
    func f1SharedOutput() {
        let h = Harness(devices: [Dev.builtInSpeakers, Dev.speaker("usb-spk"), Dev.headset("bt", "AirPods Pro")], output: "builtin-out")
        h.launch()
        #expect(Set(h.order(.output)) == ["builtin-out", "usb-spk", "bt"])
        #expect(h.order(.input) == ["bt"])
    }

    @Test("F2: first launch seeds lists with the current default first, then OS order")
    func f2Seeding() {
        let h = Harness(
            devices: [Dev.mic("m1"), Dev.mic("m2"), Dev.mic("m3"), Dev.speaker("s1"), Dev.speaker("s2")],
            input: "m3", output: "s1"
        )
        h.launch()
        #expect(h.engine.didSeedOnLaunch)
        #expect(h.order(.input) == ["m3", "m1", "m2"])
        #expect(h.order(.output) == ["s1", "s2"])
        #expect(h.audio.setCount() == 0)
    }

    @Test("F2 AC: a new USB microphone appears last in the input list")
    func f2UsbMicLast() {
        let h = Harness(devices: [Dev.builtInMic, Dev.mic("usb1")], input: "builtin-mic")
        h.launch()
        h.audio.connect(Dev.mic("usb2", "USB Microphone"))
        #expect(h.order(.input) == ["builtin-mic", "usb1", "usb2"])
        h.advance(1)
        #expect(h.def(.input) == "builtin-mic")
    }

    @Test("F2 AC: new Bluetooth headphones appear first in the output list and become the output")
    func f2BluetoothHeadphonesFirst() {
        let h = Harness(devices: [Dev.builtInSpeakers, Dev.speaker("usb")], output: "builtin-out")
        h.launch()
        h.audio.connect(AudioDevice(uid: "bt", name: "Misha’s AirPods", transport: .bluetooth, hasOutput: true))
        #expect(h.order(.output) == ["bt", "builtin-out", "usb"])
        h.advance(1.9)
        #expect(h.def(.output) == "builtin-out")
        h.advance(0.1)
        #expect(h.def(.output) == "bt")
        #expect(h.engine.lastAction?.kind == .switched)
        #expect(h.delegate.notifications.isEmpty)
    }

    @Test("F2: a new Bluetooth speaker is appended, not put first")
    func f2BluetoothSpeakerAppended() {
        let h = Harness(devices: [Dev.builtInSpeakers], output: "builtin-out")
        h.launch()
        h.audio.connect(Dev.speaker("jbl", "JBL Flip 5", transport: .bluetooth))
        #expect(h.order(.output) == ["builtin-out", "jbl"])
    }

    @Test("F2: a headset is added to both lists, each by its own rule")
    func f2HeadsetBothLists() {
        let h = Harness(devices: [Dev.builtInMic, Dev.builtInSpeakers], input: "builtin-mic", output: "builtin-out")
        h.launch()
        h.audio.connect(Dev.headset("hs", "WH-1000XM5"))
        #expect(h.order(.input) == ["builtin-mic", "hs"])
        #expect(h.order(.output) == ["hs", "builtin-out"])
    }

    @Test("F2: known devices keep their rank while disconnected and show as not connected")
    func f2KeepRank() {
        let h = Harness(outputList: [entry("a"), entry("b"), entry("c")], connected: [Dev.speaker("a"), Dev.speaker("b"), Dev.speaker("c")], output: "a")
        h.launch()
        h.audio.disconnect("b")
        h.advance(1)
        #expect(h.order(.output) == ["a", "b", "c"])
        let row = h.engine.rows(.output)[1]
        #expect(row.uid == "b" && row.rank == 2 && row.status == .notConnected)
    }

    @Test("F2: forgetting a disconnected device; on reconnect it is treated as new")
    func f2Forget() {
        let bt = AudioDevice(uid: "bt", name: "Buds", transport: .bluetooth, hasOutput: true)
        let h = Harness(outputList: [entry("spk"), entry("bt", transport: .bluetooth)], connected: [Dev.speaker("spk"), bt], output: "spk")
        h.launch()
        h.engine.forget("bt", .output) // connected: refused
        #expect(h.order(.output) == ["spk", "bt"])
        h.audio.disconnect("bt")
        h.engine.forget("bt", .output)
        #expect(h.order(.output) == ["spk"])
        h.audio.connect(bt)
        #expect(h.order(.output) == ["bt", "spk"]) // new + headphone-like → top
    }

    @Test("F2: devices that can't be default, and hidden devices, are not listed")
    func f2Eligibility() {
        let notDefault = AudioDevice(uid: "nd", name: "Loopback", transport: .virtual, hasInput: true, canBeDefaultInput: false)
        let hidden = AudioDevice(uid: "hid", name: "Hidden", transport: .virtual, hasOutput: true, isHidden: true)
        let h = Harness(devices: [Dev.builtInMic, notDefault, hidden, Dev.builtInSpeakers], input: "builtin-mic", output: "builtin-out")
        h.launch()
        #expect(h.order(.input) == ["builtin-mic"])
        #expect(h.order(.output) == ["builtin-out"])
        h.audio.connect(AudioDevice(uid: "hid2", name: "Private", transport: .other, hasOutput: true, isHidden: true))
        #expect(h.order(.output) == ["builtin-out"])
    }

    @Test("F2: aggregate, virtual and AirPlay devices are listed like any other")
    func f2SpecialTransports() {
        let h = Harness(devices: [Dev.builtInSpeakers], output: "builtin-out")
        h.launch()
        h.audio.connect(Dev.speaker("agg", "Multi-Output", transport: .aggregate))
        h.audio.connect(Dev.speaker("virt", "Soundflower", transport: .virtual))
        h.audio.connect(Dev.speaker("ap", "Living Room", transport: .airPlay))
        #expect(h.order(.output) == ["builtin-out", "agg", "virt", "ap"])
    }

    @Test("F2: devices connected at launch but unknown to stored lists are learned")
    func f2LearnAtLaunch() {
        let h = Harness(
            outputList: [entry("spk")],
            connected: [Dev.speaker("spk"), AudioDevice(uid: "bt", name: "Beats Solo", transport: .bluetooth, hasOutput: true)],
            output: "spk"
        )
        h.launch()
        #expect(h.order(.output) == ["bt", "spk"])
        #expect(h.def(.output) == "bt")
    }

    @Test("F17: list moves (drag offsets, up, down, to top)")
    func listMoves() {
        var l = RankedList([entry("a"), entry("b"), entry("c"), entry("d")])
        let r1 = l.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(r1)
        #expect(l.uids == ["b", "c", "a", "d"])
        let r2 = l.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(r2)
        #expect(l.uids == ["d", "b", "c", "a"])
        let r3 = l.move(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        #expect(!r3)
        let r4 = l.moveUp("c")
        #expect(r4)
        #expect(l.uids == ["d", "c", "b", "a"])
        let r5 = l.moveDown("d")
        #expect(r5)
        #expect(l.uids == ["c", "d", "b", "a"])
        let r6 = l.moveDown("a")
        #expect(!r6)
        let r7 = l.moveUp("c")
        #expect(!r7)
        let r8 = l.moveToTop("a")
        #expect(r8)
        #expect(l.uids == ["a", "c", "d", "b"])
        let r9 = l.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        #expect(r9)
        #expect(l.uids == ["c", "b", "a", "d"])
    }

    @Test("F17: two devices with the same name are disambiguated")
    func duplicateNames() {
        let l = RankedList([
            RankedEntry(uid: "1", name: "USB Audio", transport: .usb),
            RankedEntry(uid: "2", name: "Mic", transport: .usb),
            RankedEntry(uid: "3", name: "USB Audio", transport: .usb),
            RankedEntry(uid: "4", name: "usb audio", transport: .usb),
        ])
        let n = l.displayNames()
        #expect(n["1"] == "USB Audio")
        #expect(n["2"] == "Mic")
        #expect(n["3"] == "USB Audio (2)")
        #expect(n["4"] == "usb audio (3)")
    }

    @Test("F17: rows carry status, transport label and an accessibility summary")
    func rowsAndAccessibility() {
        let h = Harness(
            outputList: [entry("spk"), entry("pods", avoided: true, transport: .bluetooth), entry("gone")],
            connected: [Dev.speaker("spk"), AudioDevice(uid: "pods", name: "AirPods", transport: .bluetooth, hasOutput: true)],
            output: "spk"
        )
        h.launch()
        let rows = h.engine.rows(.output)
        #expect(rows.map(\.status) == [.inUse, .connected, .notConnected])
        #expect(rows[1].transport.label == "Bluetooth")
        #expect(rows[1].accessibilitySummary == "AirPods, rank 2, connected, avoided")
        #expect(Transport.hdmiDisplayPort.label == "HDMI/DisplayPort")
    }

    @Test("F17: row identity includes the direction, so a headset's input and output rows never share an id")
    func rowIdentity() {
        let h = Harness(devices: [Dev.headset("hs", "Headset", transport: .usb)], input: "hs", output: "hs")
        h.launch()
        let input = h.engine.rows(.input).first { $0.uid == "hs" }
        let output = h.engine.rows(.output).first { $0.uid == "hs" }
        #expect(input != nil && output != nil)
        #expect(input?.id != output?.id)
    }

    @Test("F2: device names are refreshed when a device reports a new name")
    func nameRefresh() {
        let h = Harness(outputList: [RankedEntry(uid: "s", name: "Old", transport: .usb)], connected: [Dev.speaker("s", "New Name")], output: "s")
        h.launch()
        #expect(h.engine.list(.output).entry("s")?.name == "New Name")
    }
}
