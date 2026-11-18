import Foundation
import Testing
@testable import PrioCore

@Suite("F2a Headphone-like classification")
struct ClassifierTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let transport: Transport
        let jack: Bool
        let expected: Bool
        init(_ name: String, _ transport: Transport, jack: Bool = false, _ expected: Bool) {
            self.name = name
            self.transport = transport
            self.jack = jack
            self.expected = expected
        }
        var testDescription: String { "\(name) [\(transport.rawValue)\(jack ? ", jack" : "")] → \(expected)" }
    }

    static let cases: [Case] = [
        // Rule 1: Bluetooth without a speaker keyword.
        Case("Misha’s Pixel Buds", .bluetooth, true),
        Case("Some BT Device", .bluetooth, true),
        Case("JBL Flip 5", .bluetooth, false),
        Case("JBL Charge 4", .bluetooth, false),
        Case("UE BOOM 3", .bluetooth, false),
        Case("Marshall Stanmore II", .bluetooth, false),
        Case("Bose SoundLink Flex", .bluetooth, false),
        Case("Living Room HomePod", .bluetooth, false),
        Case("Samsung Soundbar", .bluetooth, false),
        Case("Sound Bar 300", .bluetooth, false),
        Case("LG TV", .bluetooth, false),
        Case("Car Audio", .bluetooth, false),
        Case("Ford SYNC", .bluetooth, false),
        Case("Studio Display", .bluetooth, false),
        Case("Desk Monitor", .bluetooth, false),
        Case("Bluetooth Speaker", .bluetooth, false),
        // Speaker keywords match at word starts only.
        Case("Scarlett", .bluetooth, true),
        Case("Oscar’s phone", .bluetooth, true),
        // Rule 2: headphone keywords win over speaker keywords and transport.
        Case("AirPods Pro", .bluetooth, true),
        Case("Beats Pill speaker", .bluetooth, true),
        Case("Sony WH-1000XM4", .bluetooth, true),
        Case("Sony WF-1000XM5", .bluetooth, true),
        Case("Bose QC35 II", .bluetooth, true),
        Case("Bose QuietComfort Ultra", .bluetooth, true),
        Case("Jabra Evolve2 65", .usb, true),
        Case("Jabra Elite 85t", .bluetooth, true),
        Case("USB HEADSET", .usb, true),
        Case("Galaxy Buds2", .bluetooth, true),
        Case("Car headphones", .bluetooth, true),
        Case("Earbuds", .other, true),
        Case("External Headphones", .builtIn, true),
        // Not Bluetooth, no keyword.
        Case("USB Audio CODEC", .usb, false),
        Case("LG UltraFine Display Audio", .usb, false),
        Case("DELL U2720Q", .hdmiDisplayPort, false),
        Case("Living Room", .airPlay, false),
        // Rule 3: built-in output with headphone jack data source.
        Case("MacBook Pro Speakers", .builtIn, jack: true, true),
        Case("MacBook Pro Speakers", .builtIn, false),
        Case("USB DAC", .usb, jack: true, false),
    ]

    @Test("F2a: classification table", arguments: cases)
    func table(_ c: Case) {
        #expect(HeadphoneClassifier.isHeadphoneLike(name: c.name, transport: c.transport, dataSourceIsHeadphones: c.jack) == c.expected)
    }

    @Test("F2a: matching is case-insensitive")
    func caseInsensitive() {
        #expect(HeadphoneClassifier.isHeadphoneLike(name: "AIRPODS", transport: .usb))
        #expect(!HeadphoneClassifier.isHeadphoneLike(name: "jbl FLIP", transport: .bluetooth))
    }

    @Test("F2a: classifying a device value uses its data source")
    func deviceOverload() {
        let d = AudioDevice(uid: "b", name: "Built-in Output", transport: .builtIn, hasOutput: true, dataSourceIsHeadphones: true)
        #expect(HeadphoneClassifier.isHeadphoneLike(d))
    }
}

@Suite("F3 Target selection")
struct TargetTests {
    let list = RankedList([entry("a"), entry("b", avoided: true), entry("c"), entry("d", avoided: true)])

    @Test("F3.1: a valid manual pick wins, even if avoided or ranked low")
    func manualPick() {
        #expect(TargetSelector.select(list: list, connected: ["a", "b", "c"], manualPick: "c") == Target(uid: "c", reason: .manualPick))
        #expect(TargetSelector.select(list: list, connected: ["a", "b"], manualPick: "b") == Target(uid: "b", reason: .manualPick))
    }

    @Test("F3.1: a manual pick that is not connected is ignored")
    func stalePick() {
        #expect(TargetSelector.select(list: list, connected: ["c"], manualPick: "a") == Target(uid: "c", reason: .ranked))
    }

    @Test("F3.2: highest-ranked connected, non-avoided device")
    func ranked() {
        #expect(TargetSelector.select(list: list, connected: ["a", "c"], manualPick: nil) == Target(uid: "a", reason: .ranked))
        #expect(TargetSelector.select(list: list, connected: ["b", "c", "d"], manualPick: nil) == Target(uid: "c", reason: .ranked))
    }

    @Test("F3.3: only avoided devices connected → highest-ranked avoided one, as last resort")
    func lastResort() {
        let t = TargetSelector.select(list: list, connected: ["d", "b"], manualPick: nil)
        #expect(t == Target(uid: "b", reason: .lastResort))
        #expect(t?.isLastResort == true)
    }

    @Test("F3.4: nothing listed is connected → no target")
    func none() {
        #expect(TargetSelector.select(list: list, connected: [], manualPick: nil) == nil)
        #expect(TargetSelector.select(list: list, connected: ["unlisted"], manualPick: nil) == nil)
        #expect(TargetSelector.select(list: RankedList(), connected: ["a"], manualPick: nil) == nil)
    }

    @Test("F3: deterministic regardless of set ordering")
    func deterministic() {
        for _ in 0..<50 {
            let connected = Set(["d", "c", "b", "a"].shuffled())
            #expect(TargetSelector.select(list: list, connected: connected, manualPick: nil)?.uid == "a")
        }
    }
}
