import AppKit
import Foundation
import PrioCore
import ServiceManagement
import UserNotifications

// MARK: - Clock

/// Real clock for the engine: wall time plus main-queue timers (no polling).
@MainActor
final class DispatchClock: EngineClock {
    private final class Handle: Cancellable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    var now: Date { Date() }

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Cancellable {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return Handle(item)
    }
}

// MARK: - Storage

/// Stores state as JSON in ~/Library/Application Support/Prio/state.json.
@MainActor
final class FileStateStore: StateStore {
    let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        url = base.appendingPathComponent("Prio", isDirectory: true).appendingPathComponent("state.json")
    }

    func load() -> Data? {
        try? Data(contentsOf: url)
    }

    func save(_ data: Data) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Prio: could not save state: \(error.localizedDescription)")
        }
    }
}

// MARK: - Launch at login (F18)

@MainActor
enum LoginItem {
    enum State {
        case enabled
        case disabled
        case needsApproval
        case unavailable
    }

    static var state: State {
        guard AppInfo.isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .disabled
        case .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Returns an error message, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        guard AppInfo.isBundled else { return "Launch at login needs Prio to run from its app bundle." }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Notifications (F14)

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let correctionCategory = "PRIO_CORRECTION"
    nonisolated static let undoAction = "PRIO_UNDO"

    /// Called with the action ID when the user presses Undo on a notification.
    var onUndo: ((Int) -> Void)?

    private var center: UNUserNotificationCenter? {
        AppInfo.isBundled ? UNUserNotificationCenter.current() : nil
    }

    /// Must run early (applicationWillFinishLaunching) so an Undo tap that
    /// launches the app is still delivered.
    func configure() {
        guard let center else { return }
        center.delegate = self
        let undo = UNNotificationAction(identifier: Self.undoAction, title: "Undo", options: [])
        let category = UNNotificationCategory(identifier: Self.correctionCategory, actions: [undo], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    /// The system only shows the prompt once; if denied, everything else still works.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ n: PrioNotification) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.body = n.body
        if let id = n.undoActionID {
            content.categoryIdentifier = Self.correctionCategory
            content.userInfo = ["actionID": id]
        }
        // One slot per kind and direction: a newer notification replaces an older one.
        let identifier = "prio.\(n.kind.rawValue).\(n.direction.rawValue)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isUndo = response.actionIdentifier == Self.undoAction
        let id = response.notification.request.content.userInfo["actionID"] as? Int
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if isUndo, let id { self.onUndo?(id) }
            }
        }
        completionHandler()
    }
}
