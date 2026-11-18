#if DEBUG
import AppKit
import PrioCore
import SwiftUI

/// Developer aid (debug builds only): renders the menu and settings views
/// with sample devices to PNG files, in light and dark appearance.
/// Usage: swift run Prio --snapshots <output-folder>
@MainActor
enum DebugSnapshots {
    private final class SampleAudio: AudioSystem {
        var list: [AudioDevice] = [
            AudioDevice(uid: "mic", name: "MacBook Pro Microphone", transport: .builtIn, hasInput: true),
            AudioDevice(uid: "yeti", name: "Yeti Stereo Microphone", transport: .usb, hasInput: true),
            AudioDevice(uid: "pods", name: "AirPods Pro", transport: .bluetooth, hasInput: true, hasOutput: true),
            AudioDevice(uid: "spk", name: "MacBook Pro Speakers", transport: .builtIn, hasOutput: true),
            AudioDevice(uid: "dell", name: "DELL P2415Q with a very long display name", transport: .hdmiDisplayPort, hasOutput: true),
        ]
        var defaults: [Direction: String] = [.input: "mic", .output: "pods"]
        func devices() -> [AudioDevice] { list }
        func defaultDevice(_ direction: Direction) -> String? { defaults[direction] }
        func setDefaultDevice(_ direction: Direction, uid: String) -> Bool {
            defaults[direction] = uid
            return true
        }
    }

    private final class MemoryStore: StateStore {
        var data: Data?
        func load() -> Data? { data }
        func save(_ data: Data) { self.data = data }
    }

    static func run(outputFolder: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let audio = SampleAudio()
        let store = MemoryStore()
        var state = PersistedState()
        state.inputList = RankedList([
            RankedEntry(uid: "mic", name: "MacBook Pro Microphone", transport: .builtIn),
            RankedEntry(uid: "yeti", name: "Yeti Stereo Microphone", transport: .usb),
            RankedEntry(uid: "pods", name: "AirPods Pro", transport: .bluetooth, avoided: true),
            RankedEntry(uid: "usb2", name: "USB Audio", transport: .usb),
            RankedEntry(uid: "usb3", name: "USB Audio", transport: .usb),
        ])
        state.outputList = RankedList([
            RankedEntry(uid: "pods", name: "AirPods Pro", transport: .bluetooth),
            RankedEntry(uid: "spk", name: "MacBook Pro Speakers", transport: .builtIn),
            RankedEntry(uid: "dell", name: "DELL P2415Q with a very long display name", transport: .hdmiDisplayPort, avoided: true),
            RankedEntry(uid: "hp", name: "Living Room", transport: .airPlay),
        ])
        store.data = state.encoded()
        let engine = Engine(audio: audio, clock: DispatchClock(), store: store)
        let model = AppModel(engine: engine, notifications: NotificationManager()) { false }
        engine.delegate = model
        engine.start()
        engine.pick("spk", .output)
        audio.defaults[.input] = "yeti"
        engine.defaultDidChange(.input) // corrected → last action with Undo
        model.refresh()

        let dir = URL(fileURLWithPath: outputFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let navigator = MenuNavigator(model: model)
            navigator.expanded = .output
            navigator.highlighted = .device(.output, "dell")
            render(MenuView(model: model, navigator: navigator), name, dir.appendingPathComponent("menu-\(suffix).png"))
            render(DevicesTab(model: model, direction: .input), name, dir.appendingPathComponent("devices-\(suffix).png"))
            render(GeneralTab(model: model), name, dir.appendingPathComponent("general-\(suffix).png"))
        }
        for v in [StatusIcon.Variant.normal, .muted, .paused] {
            let img = StatusIcon.image(v)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 72, height: 72).fill()
            img.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("status-\(v).png"))
        }
        print("Snapshots written to \(dir.path)")
    }

    private static func render<V: View>(_ view: V, _ appearance: NSAppearance.Name, _ url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
