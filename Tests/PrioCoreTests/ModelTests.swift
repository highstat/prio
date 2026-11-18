import Testing
@testable import PrioCore

@Suite("Model basics")
struct ModelBasicsTests {
    @Test("F17: every transport has a user-facing label")
    func transportLabels() {
        #expect(Transport.allCases.map(\.label) == [
            "Built-in", "USB", "Bluetooth", "HDMI/DisplayPort", "Thunderbolt", "AirPlay", "Virtual", "Aggregate", "Other",
        ])
    }

    @Test("F2: eligibility needs streams, can-be-default and not hidden; usability also needs liveness")
    func eligibility() {
        let d = AudioDevice(uid: "x", name: "X", transport: .usb, hasInput: true, hasOutput: true, canBeDefaultOutput: false, isAlive: false)
        #expect(d.isEligible(for: .input))
        #expect(!d.isEligible(for: .output))
        #expect(!d.isUsable(for: .input))
    }
}
