import PrioCore
import SwiftUI

/// Contents of the menu bar popover (F16).
struct MenuView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    var quit: () -> Void

    @ViewState private var expanded: Direction?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, initiallyExpanded: Direction? = nil, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.quit = quit
        _expanded = ViewState(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            autoToggle
            separator
            DeviceSection(model: model, direction: .input, expanded: $expanded, toggle: toggle)
            DeviceSection(model: model, direction: .output, expanded: $expanded, toggle: toggle)
            separator
            LastActionView(model: model)
            separator
            MenuCommand(title: "Settings…", shortcut: "⌘,", action: openSettings)
                .keyboardShortcut(",", modifiers: .command)
            MenuCommand(title: "Quit Prio", shortcut: "⌘Q", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .tint(.prioAccent)
    }

    private func toggle(_ d: Direction) {
        let change = { expanded = expanded == d ? nil : d }
        if reduceMotion {
            change()
        } else {
            withAnimation(.easeInOut(duration: 0.15), change)
        }
    }

    private var autoToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: model.binding(\.automaticSwitching)) {
                Text("Automatic switching")
                    .font(.body.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if !model.settings.automaticSwitching {
                Text("Paused. macOS picks devices on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var separator: some View {
        Divider().padding(.vertical, 4).padding(.horizontal, 10)
    }
}

/// Input or output: the current device, expandable into the ranked list.
private struct DeviceSection: View {
    @ObservedObject var model: AppModel
    let direction: Direction
    @Binding var expanded: Direction?
    let toggle: (Direction) -> Void

    private var isExpanded: Bool { expanded == direction }

    var body: some View {
        let current = model.current(direction)
        VStack(alignment: .leading, spacing: 0) {
            HoverButton(action: { toggle(direction) }) {
                HStack(spacing: 8) {
                    Image(systemName: current.map(deviceSymbol) ?? (direction == .input ? "mic" : "speaker.wave.2"))
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(direction.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(current?.displayName ?? "None")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(current?.name ?? "")
                    }
                    Spacer(minLength: 4)
                    if current?.isManualPick == true {
                        PinnedBadge()
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("\(direction.label): \(current?.displayName ?? "none")")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            .accessibilityHint("Shows all connected \(direction.lowercaseLabel) devices")

            if isExpanded {
                DeviceList(model: model, direction: direction)
            }
        }
    }
}

private struct DeviceList: View {
    @ObservedObject var model: AppModel
    let direction: Direction

    var body: some View {
        let rows = model.menuRows(direction)
        Group {
            if rows.isEmpty {
                Text("No \(direction.lowercaseLabel) devices connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 4)
            } else if rows.count > 8 {
                ScrollView {
                    content(rows)
                }
                .frame(height: 8 * 26)
            } else {
                content(rows)
            }
        }
        .padding(.bottom, 4)
    }

    private func content(_ rows: [DeviceRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                MenuDeviceRow(row: row) {
                    model.engine.pick(row.uid, direction)
                }
            }
        }
    }
}

private struct MenuDeviceRow: View {
    let row: DeviceRow
    let action: () -> Void

    var body: some View {
        HoverButton(action: action) {
            HStack(spacing: 8) {
                Text("\(row.rank)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                Text(row.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.name)
                    .foregroundStyle(row.isUsable ? .primary : .secondary)
                Spacer(minLength: 4)
                if !row.isUsable {
                    Text("Not ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if row.isAvoided {
                    Text("Avoided")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if row.isManualPick {
                    PinnedBadge()
                }
                Image(systemName: "checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.prioAccent)
                    .opacity(row.isDefault ? 1 : 0)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 12)
        }
        .disabled(!row.isUsable)
        .accessibilityLabel(menuAccessibilityLabel)
        .accessibilityHint("Selects this device and keeps it until it disconnects or a higher-ranked device connects")
    }

    private var menuAccessibilityLabel: String {
        var parts = [row.displayName, "rank \(row.rank)"]
        if row.isDefault { parts.append("in use") }
        if !row.isUsable { parts.append("not ready") }
        if row.isAvoided { parts.append("avoided") }
        if row.isManualPick { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}

/// Marks the manual pick. Accent outline plus text, never color alone.
struct PinnedBadge: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(Color.prioAccent)
            Text("Pinned")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .overlay(Capsule().strokeBorder(Color.prioAccent, lineWidth: 1))
        .help("You picked this device. Prio keeps it until it disconnects or a higher-ranked device connects.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pinned")
    }
}

private struct LastActionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let a = model.lastAction {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.sentence)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        // Recomputed whenever the menu opens (no timers while idle, R9).
                        Text(relative(a.date, now: Date()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if model.canUndo {
                        Button("Undo") { model.engine.undo() }
                            .controlSize(.small)
                            .accessibilityHint("Restores the previous device and pins it")
                    }
                }
                .accessibilityElement(children: .contain)
            } else {
                Text("No recent changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Direction.allCases, id: \.self) { d in
                if model.loopActive[d] == true {
                    Label("Not correcting \(d.lowercaseLabel): something keeps changing it.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}

private struct MenuCommand: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        HoverButton(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(title)
    }
}

/// A full-width, menu-like row button with a hover highlight.
struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(hovering && isEnabled ? (contrast == .increased ? 0.2 : 0.1) : 0))
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}
