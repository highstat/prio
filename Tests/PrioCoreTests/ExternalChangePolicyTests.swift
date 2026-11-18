import Foundation
import Testing
@testable import PrioCore

@Suite("F7 External change policy (pure)")
struct ExternalChangePolicyTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func change(
        isTarget: Bool = false,
        previousStillConnected: Bool = true,
        attribution: Attribution = .user,
        respects: Bool = false,
        loopProtected: Bool = false
    ) -> ExternalChange {
        ExternalChange(
            isTarget: isTarget,
            previousStillConnected: previousStillConnected,
            attribution: attribution,
            respectsExternalChanges: respects,
            loopProtectionActive: loopProtected
        )
    }

    @Test("A change to the target needs nothing")
    func target() {
        #expect(ExternalChangePolicy.decide(change(isTarget: true)) == .alreadyOnTarget)
    }

    @Test("macOS falling back because the default vanished is a plain fallback")
    func fallback() {
        #expect(ExternalChangePolicy.decide(change(previousStillConnected: false, attribution: .macOS)) == .fallback)
    }

    @Test("Rule 1: attributed to macOS → correct, even when respecting changes")
    func macOS() {
        #expect(ExternalChangePolicy.decide(change(attribution: .macOS, respects: true)) == .correct)
    }

    @Test("Rule 2: attributed to the user and respected → adopt as manual pick")
    func respected() {
        #expect(ExternalChangePolicy.decide(change(attribution: .user, respects: true)) == .adoptAsManualPick)
    }

    @Test("Rule 2: attributed to the user and not respected → correct")
    func notRespected() {
        #expect(ExternalChangePolicy.decide(change(attribution: .user, respects: false)) == .correct)
    }

    @Test("F9: a correction is left alone while loop protection is active")
    func loopProtected() {
        #expect(ExternalChangePolicy.decide(change(attribution: .macOS, loopProtected: true)) == .leaveAlone)
        #expect(ExternalChangePolicy.decide(change(attribution: .user, respects: true, loopProtected: true)) == .adoptAsManualPick)
    }

    @Test("Attribution: topology within 3 s or wake within 5 s is macOS, boundaries inclusive")
    func attribution() {
        #expect(Attribution.of(now: t0 + 3.0, lastTopologyChange: t0, lastWake: nil) == .macOS)
        #expect(Attribution.of(now: t0 + 3.1, lastTopologyChange: t0, lastWake: nil) == .user)
        #expect(Attribution.of(now: t0 + 5.0, lastTopologyChange: nil, lastWake: t0) == .macOS)
        #expect(Attribution.of(now: t0 + 5.1, lastTopologyChange: nil, lastWake: t0) == .user)
        #expect(Attribution.of(now: t0, lastTopologyChange: nil, lastWake: nil) == .user)
    }
}
