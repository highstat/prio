import AppKit
import SwiftUI

/// Standard settings window with Devices and General tabs (F17, F18).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true

        let devices = NSHostingController(rootView: DevicesTab(model: model))
        devices.sizingOptions = .preferredContentSize
        devices.title = "Devices"
        let devicesItem = NSTabViewItem(viewController: devices)
        devicesItem.label = "Devices"
        devicesItem.image = NSImage(systemSymbolName: "list.number", accessibilityDescription: "Devices")

        let general = NSHostingController(rootView: GeneralTab(model: model))
        general.sizingOptions = .preferredContentSize
        general.title = "General"
        let generalItem = NSTabViewItem(viewController: general)
        generalItem.label = "General"
        generalItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")

        tabs.addTabViewItem(devicesItem)
        tabs.addTabViewItem(generalItem)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PrioSettings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.refresh()
        model.refreshLoginItem()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
