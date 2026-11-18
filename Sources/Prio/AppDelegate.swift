import AppKit
import PrioAudio
import PrioCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audio = CoreAudioSystem()
    private let clock = DispatchClock()
    private let store = FileStateStore()
    private let notifications = NotificationManager()
    private var engine: Engine!
    private var model: AppModel!
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var observers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set the notification delegate before launch finishes so an Undo tap
        // that launched the app is delivered.
        notifications.configure()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar only, also when run unbundled
        NSApp.mainMenu = makeMainMenu()

        engine = Engine(audio: audio, clock: clock, store: store)
        model = AppModel(engine: engine, notifications: notifications) { [audio] in audio.isDefaultInputMuted() }
        engine.delegate = model
        notifications.onUndo = { [weak self] id in self?.engine.undo(actionID: id) }

        audio.onDevicesChanged = { [weak self] in self?.engine.devicesDidChange() }
        audio.onDefaultChanged = { [weak self] d in self?.engine.defaultDidChange(d) }
        audio.onInputMuteChanged = { [weak self] in self?.model.refresh() }

        statusItem = StatusItemController(model: model) { [weak self] in self?.showSettings() }
        model.onRefresh = { [weak self] in self?.statusItem?.updateIcon() }
        statusItem?.hasOtherVisibleWindow = { [weak self] in self?.settingsWindow?.window?.isVisible == true }

        observeWorkspace()
        audio.startListening()
        engine.start()
        model.refreshLoginItem()
        notifications.requestAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio.stopListening()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (e.g. from Finder) shows Settings, since there is no Dock icon.
        showSettings()
        return false
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show()
    }

    // MARK: - Sleep, wake and session (F8, F12)

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (Engine) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let engine = self?.engine else { return }
                    handler(engine)
                }
            })
        }
        on(NSWorkspace.willSleepNotification) { $0.systemWillSleep() }
        on(NSWorkspace.didWakeNotification) { $0.systemDidWake() }
        on(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionDidResignActive() }
        on(NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionDidBecomeActive() }
    }

    // MARK: - Main menu (key equivalents while Settings is open)

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Prio")
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Prio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Prio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }
}
