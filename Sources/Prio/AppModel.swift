import AppKit
import Combine
import PrioCore
import SwiftUI

/// Bridges the engine to SwiftUI views and the status item.
@MainActor
final class AppModel: ObservableObject, EngineDelegate {
    let engine: Engine
    let notifications: NotificationManager
    /// Reads the mute state of the default input (F15).
    private let isInputMuted: () -> Bool

    @Published private(set) var inputRows: [DeviceRow] = []
    @Published private(set) var outputRows: [DeviceRow] = []
    @Published private(set) var settings = PrioSettings()
    @Published private(set) var lastAction: ActionRecord?
    @Published private(set) var canUndo = false
    @Published private(set) var inputMuted = false
    @Published private(set) var loopActive: [Direction: Bool] = [:]
    @Published private(set) var loginItemState: LoginItem.State = .unavailable
    @Published var loginItemError: String?

    /// Row order frozen while the menu is open, so rows never jump under the pointer (F16).
    private var frozenOrder: [Direction: [String]]?

    /// Called after every refresh (used by the status item icon).
    var onRefresh: (() -> Void)?

    init(engine: Engine, notifications: NotificationManager, isInputMuted: @escaping () -> Bool) {
        self.engine = engine
        self.notifications = notifications
        self.isInputMuted = isInputMuted
    }

    // MARK: EngineDelegate

    func engineDidChange(_ engine: Engine) {
        refresh()
    }

    func engine(_ engine: Engine, post notification: PrioNotification) {
        notifications.post(notification)
    }

    func refresh() {
        inputRows = engine.rows(.input)
        outputRows = engine.rows(.output)
        settings = engine.settings
        lastAction = engine.lastAction
        canUndo = engine.canUndo
        inputMuted = isInputMuted()
        loopActive = [.input: engine.isLoopProtectionActive(.input), .output: engine.isLoopProtectionActive(.output)]
        onRefresh?()
    }

    func refreshLoginItem() {
        loginItemState = LoginItem.state
    }

    // MARK: Menu helpers

    func rows(_ d: Direction) -> [DeviceRow] {
        d == .input ? inputRows : outputRows
    }

    /// Connected devices in rank order, for the menu. While the menu is open,
    /// rows keep the order they had when it opened; newcomers go last.
    func menuRows(_ d: Direction) -> [DeviceRow] {
        let connected = rows(d).filter(\.isConnected)
        guard let order = frozenOrder?[d] else { return connected }
        return connected.sorted { a, b in
            let ia = order.firstIndex(of: a.uid) ?? Int.max
            let ib = order.firstIndex(of: b.uid) ?? Int.max
            return ia == ib ? a.rank < b.rank : ia < ib
        }
    }

    func current(_ d: Direction) -> DeviceRow? {
        rows(d).first(where: \.isDefault)
    }

    func menuWillOpen() {
        refresh()
        frozenOrder = [.input: rows(.input).map(\.uid), .output: rows(.output).map(\.uid)]
    }

    func menuDidClose() {
        frozenOrder = nil
    }

    // MARK: Bindings

    func binding(_ keyPath: WritableKeyPath<PrioSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.engine.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { self.loginItemState == .enabled || self.loginItemState == .needsApproval },
            set: { value in
                self.loginItemError = LoginItem.set(value)
                self.refreshLoginItem()
            }
        )
    }

    // MARK: Diagnostics

    func diagnostics(includeNames: Bool) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return Diagnostics.report(
            engine: engine,
            environment: DiagnosticsEnvironment(appVersion: AppInfo.version, osVersion: osText, architecture: Self.architecture),
            includeNames: includeNames
        )
    }

    static var architecture: String {
        #if arch(arm64)
        let built = "arm64"
        #elseif arch(x86_64)
        let built = "x86_64"
        #else
        let built = "unknown"
        #endif
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
        return rosetta ? "\(built) (Rosetta)" : built
    }
}
