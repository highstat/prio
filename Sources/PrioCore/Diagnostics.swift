import Foundation

public struct DiagnosticsEnvironment: Sendable {
    public var appVersion: String
    public var osVersion: String
    public var architecture: String

    public init(appVersion: String, osVersion: String, architecture: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.architecture = architecture
    }
}

/// F19. Device UIDs are never included: they can contain hardware addresses or product names.
public enum Diagnostics {
    @MainActor
    public static func report(engine: Engine, environment env: DiagnosticsEnvironment, includeNames: Bool) -> String {
        let labelFor = labeler(engine: engine, includeNames: includeNames)
        var out: [String] = []
        out.append("Prio diagnostics")
        out.append("Prio version: \(env.appVersion)")
        out.append("macOS version: \(env.osVersion)")
        out.append("Architecture: \(env.architecture)")
        out.append("Session active: \(yesNo(engine.isSessionActive))")
        out.append("")

        let s = engine.settings
        out.append("Settings")
        out.append("  Automatic switching: \(onOff(s.automaticSwitching))")
        out.append("  Notifications: \(onOff(s.notificationsEnabled))")
        out.append("  Notify on every switch: \(onOff(s.notifyOnEverySwitch))")
        out.append("  Respect output changes made outside Prio: \(onOff(s.respectOutputChanges))")
        out.append("  Respect input changes made outside Prio: \(onOff(s.respectInputChanges))")

        for d in Direction.allCases {
            out.append("")
            out.append("\(d.label) list")
            let label = labelFor(d)
            let rows = engine.rows(d)
            if rows.isEmpty { out.append("  (empty)") }
            for r in rows {
                var flags: [String] = [r.transport.label, r.status.rawValue]
                if r.isConnected && !r.isUsable { flags.append("not ready") }
                if r.isAvoided { flags.append("avoided") }
                if r.isManualPick { flags.append("manual pick") }
                out.append("  \(r.rank). \(label(r.uid, r.name)) — \(flags.joined(separator: ", "))")
            }
            let current = engine.currentDefault(d).map { label($0, nil) } ?? "none"
            out.append("  Current default: \(current)")
            out.append("  Manual pick: \(engine.manualPick(d).map { label($0, nil) } ?? "none")")
            let target = engine.target(d)
            out.append("  Target: \(target.map { "\(label($0.uid, nil)) (\(reason($0.reason)))" } ?? "none")")
            let loop = engine.loopInfo(d)
            out.append("  Loop protection: \(loop.isActive ? "active" : "off") (\(loop.recentAttempts) recent attempts)")
        }

        out.append("")
        out.append("Recent actions (newest last)")
        if engine.history.isEmpty { out.append("  (none)") }
        let now = engine.now
        for a in engine.history {
            let ago = Int(now.timeIntervalSince(a.date).rounded())
            out.append("  -\(ago)s [\(a.direction.rawValue)] \(a.kind.rawValue): \(a.sentence(name: labelFor(a.direction)))")
        }
        return out.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func labeler(engine: Engine, includeNames: Bool) -> (Direction) -> (String?, String?) -> String {
        var anon: [Direction: [String: String]] = [:]
        var names: [Direction: [String: String]] = [:]
        for d in Direction.allCases {
            let list = engine.list(d)
            let display = list.displayNames()
            for (i, e) in list.entries.enumerated() {
                anon[d, default: [:]][e.uid] = "\(d.label) \(i + 1)"
                names[d, default: [:]][e.uid] = display[e.uid] ?? e.name
            }
        }
        return { d in
            let other: Direction = d == .input ? .output : .input
            return { uid, storedName in
                guard let uid else { return "unknown device" }
                if includeNames {
                    return names[d]?[uid] ?? names[other]?[uid] ?? storedName ?? "unlisted device"
                }
                return anon[d]?[uid] ?? anon[other]?[uid] ?? "unlisted \(d.lowercaseLabel) device"
            }
        }
    }

    private static func onOff(_ b: Bool) -> String { b ? "on" : "off" }
    private static func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }
    private static func reason(_ r: Target.Reason) -> String {
        switch r {
        case .manualPick: return "manual pick"
        case .ranked: return "ranking"
        case .lastResort: return "last resort"
        }
    }
}
