import AppKit
import SwiftUI

/// Devices and General tabs (F17, F18). Created on demand, released on close.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: () -> Void = {}
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
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        super.init(window: window)
        window.delegate = self
    }

    private static let frameName = "PrioSettings"

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.refresh()
        model.refreshLoginItem()
        NSApp.activateIgnoringOtherApps()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
