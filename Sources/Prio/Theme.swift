import AppKit
import PrioCore
import SwiftUI

/// Project-wide constants.
enum AppInfo {
    /// The one place the source code URL is defined. Opened only on click.
    static let sourceURL = URL(string: "https://github.com/highstat/prio")!
    static let sourceURLText = "github.com/highstat/prio"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Notifications and login items need a real .app bundle.
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
}

extension NSColor {
    /// The single accent color: teal #0D9488, lighter in dark mode, with
    /// stronger variants for Increase Contrast.
    static let prioAccent = NSColor(name: NSColor.Name("PrioAccent")) { appearance in
        switch appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]) {
        case .darkAqua?:
            return NSColor(srgbRed: 0x2D / 255, green: 0xBF / 255, blue: 0xB0 / 255, alpha: 1) // lighter teal
        case .accessibilityHighContrastAqua?:
            return NSColor(srgbRed: 0x0B / 255, green: 0x6E / 255, blue: 0x66 / 255, alpha: 1) // darker teal
        case .accessibilityHighContrastDarkAqua?:
            return NSColor(srgbRed: 0x5E / 255, green: 0xEA / 255, blue: 0xD4 / 255, alpha: 1) // brightest teal
        default:
            return NSColor(srgbRed: 0x0D / 255, green: 0x94 / 255, blue: 0x88 / 255, alpha: 1) // #0D9488
        }
    }
}

extension Color {
    static let prioAccent = Color(nsColor: .prioAccent)
}

extension NSApplication {
    /// `activate(ignoringOtherApps:)` is deprecated from macOS 14.
    func activateIgnoringOtherApps() {
        if #available(macOS 14, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}

/// SF Symbol for a device row ("type glyph").
func deviceSymbol(name: String, transport: Transport, direction: Direction) -> String {
    if HeadphoneClassifier.isHeadphoneLike(name: name, transport: transport) {
        return "headphones"
    }
    switch transport {
    case .builtIn: return direction == .input ? "mic" : "speaker.wave.2"
    case .hdmiDisplayPort: return "display"
    case .airPlay: return "airplayaudio"
    case .virtual: return "waveform"
    case .aggregate: return "square.stack.3d.up"
    case .usb, .bluetooth, .thunderbolt, .other: return direction == .input ? "mic" : "hifispeaker"
    }
}

func deviceSymbol(_ row: DeviceRow) -> String {
    deviceSymbol(name: row.name, transport: row.transport, direction: row.direction)
}

/// In newer SDKs `@State` resolves to a SwiftUI macro whose compiler plugin
/// ships only with full Xcode. Referring to the property wrapper type through
/// a typealias keeps the classic property wrapper, so Prio still builds with
/// just the Command Line Tools (R6).
typealias ViewState<Value> = SwiftUI.State<Value>
