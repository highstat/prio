import AppKit
import SwiftUI

/// Owns the menu bar item; the popover content is built on open and released on close (F15, F16).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private let openSettings: () -> Void
    private var navigator: MenuNavigator?
    private var keyMonitor: Any?
    private var lastIcon: StatusIcon.Variant?
    var hasOtherVisibleWindow: () -> Bool = { false }

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()
    }

    func updateIcon() {
        let variant: StatusIcon.Variant = !model.settings.automaticSwitching ? .paused : (model.inputMuted ? .muted : .normal)
        guard variant != lastIcon, let button = statusItem.button else { return }
        lastIcon = variant
        button.image = StatusIcon.image(variant)
        button.setAccessibilityLabel(variant.accessibilityLabel)
        button.toolTip = variant.accessibilityLabel
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.menuWillOpen()
        let navigator = MenuNavigator(model: model)
        navigator.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            self?.openSettings()
        }
        navigator.quit = { NSApp.terminate(nil) }
        self.navigator = navigator
        let hosting = NSHostingController(rootView: MenuView(model: model, navigator: navigator))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode, flags = event.modifierFlags, characters = event.charactersIgnoringModifiers
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                self?.handleKey(keyCode: keyCode, flags: flags, characters: characters, windowNumber: windowNumber) ?? false
            }
            return handled ? nil : event
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        popover.contentViewController = nil
        navigator = nil
        model.menuDidClose()
        // Give keyboard focus back to the previous app, as a menu would.
        if !hasOtherVisibleWindow() { NSApp.deactivate() }
    }

    private enum Key: UInt16 {
        case tab = 48, space = 49, returnKey = 36, enter = 76
        case left = 123, right = 124, down = 125, up = 126
    }

    private func handleKey(keyCode: UInt16, flags rawFlags: NSEvent.ModifierFlags, characters: String?, windowNumber: Int) -> Bool {
        guard let navigator, windowNumber == popover.contentViewController?.view.window?.windowNumber else { return false }
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch characters {
            case ",": navigator.activate(.settings)
            case "q": navigator.activate(.quit)
            default: return false
            }
            return true
        }
        guard let key = Key(rawValue: keyCode) else { return false }
        switch key {
        case .down: navigator.move(1)
        case .up: navigator.move(-1)
        case .tab: navigator.move(flags.contains(.shift) ? -1 : 1)
        case .returnKey, .enter, .space: navigator.activate()
        case .right: navigator.expandHighlighted(true)
        case .left: navigator.expandHighlighted(false)
        }
        return true
    }
}

/// Monochrome template glyph: three bars of decreasing length, a ranked list.
enum StatusIcon {
    enum Variant: Equatable {
        case normal, muted, paused

        var accessibilityLabel: String {
            switch self {
            case .normal: return "Prio"
            case .muted: return "Prio, input muted"
            case .paused: return "Prio, automatic switching paused"
            }
        }
    }

    static func image(_ variant: Variant) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            draw(variant)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ variant: Variant) {
        NSColor.black.setFill()
        let barHeight: CGFloat = 2.6
        let x: CGFloat = 2
        let widths: [CGFloat] = variant == .paused ? [9, 7, 5] : [14, 10.5, 7]
        let tops: [CGFloat] = [3.7, 7.7, 11.7]
        for (i, w) in widths.enumerated() {
            let rect = NSRect(x: x, y: tops[i], width: w, height: barHeight)
            let alpha: CGFloat = variant == .paused ? 0.55 : 1
            NSColor.black.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }
        switch variant {
        case .normal:
            break
        case .paused:
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 12.2, y: 5, width: 1.9, height: 8.5), xRadius: 0.9, yRadius: 0.9).fill()
            NSBezierPath(roundedRect: NSRect(x: 15.2, y: 5, width: 1.9, height: 8.5), xRadius: 0.9, yRadius: 0.9).fill()
        case .muted:
            // Knock out a gap, then draw the slash.
            let start = NSPoint(x: 2.5, y: 2)
            let end = NSPoint(x: 15.5, y: 16)
            let gap = NSBezierPath()
            gap.move(to: start)
            gap.line(to: end)
            gap.lineWidth = 4
            gap.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            gap.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let slash = NSBezierPath()
            slash.move(to: start)
            slash.line(to: end)
            slash.lineWidth = 1.6
            slash.lineCapStyle = .round
            NSColor.black.setStroke()
            slash.stroke()
        }
    }
}
