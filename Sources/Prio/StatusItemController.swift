import AppKit
import SwiftUI

/// Owns the menu bar item and its popover (F15, F16).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var lastIcon: StatusIcon.Variant?
    /// True while another Prio window (Settings) is open.
    var hasOtherVisibleWindow: () -> Bool = { false }

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        super.init()
        let hosting = NSHostingController(rootView: MenuView(
            model: model,
            openSettings: { [weak self] in
                self?.popover.performClose(nil)
                openSettings()
            },
            quit: { NSApp.terminate(nil) }
        ))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()
    }

    func updateIcon() {
        let variant: StatusIcon.Variant
        if !model.settings.automaticSwitching {
            variant = .paused
        } else if model.inputMuted {
            variant = .muted
        } else {
            variant = .normal
        }
        guard variant != lastIcon, let button = statusItem.button else { return }
        lastIcon = variant
        button.image = StatusIcon.image(variant)
        let description: String
        switch variant {
        case .normal: description = "Prio"
        case .muted: description = "Prio, input muted"
        case .paused: description = "Prio, automatic switching paused"
        }
        button.setAccessibilityLabel(description)
        button.toolTip = description
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        model.menuWillOpen()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        model.menuDidClose()
        // Give keyboard focus back to the previous app, like a menu would.
        if !hasOtherVisibleWindow() {
            NSApp.deactivate()
        }
    }
}

/// Monochrome template glyph: three bars of decreasing length, a ranked list.
enum StatusIcon {
    enum Variant: Equatable {
        case normal
        case muted
        case paused
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
