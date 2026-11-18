import AppKit

// Prio: keeps the Mac on the audio devices you prefer. Menu bar only.
MainActor.assumeIsolated {
    #if DEBUG
    if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count {
        DebugSnapshots.run(outputFolder: CommandLine.arguments[i + 1])
        exit(0)
    }
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
