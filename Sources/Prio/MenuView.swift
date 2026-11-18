import PrioCore
import SwiftUI

/// Contents of the menu bar popover (F16).
struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigator: MenuNavigator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AutomaticSwitchingRow(model: model, navigator: navigator)
            MenuDivider()
            DeviceSection(model: model, navigator: navigator, direction: .input)
            DeviceSection(model: model, navigator: navigator, direction: .output)
            MenuDivider()
            LastActionView(model: model, navigator: navigator)
            MenuDivider()
            MenuRow(navigator: navigator, item: .settings, label: "Settings…") { _ in
                CommandLabel(title: "Settings…", shortcut: "⌘,")
            }
            MenuRow(navigator: navigator, item: .quit, label: "Quit Prio") { _ in
                CommandLabel(title: "Quit Prio", shortcut: "⌘Q")
            }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .tint(.prioAccent)
        .animation(Motion.standard(reduceMotion), value: navigator.expanded)
    }
}

enum Motion {
    /// Short ease-out used for every transition; none with Reduce Motion.
    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    static func hover(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider().padding(.vertical, 5).padding(.horizontal, 14)
    }
}

/// A full-width row whose highlight follows both the pointer and the keyboard.
private struct MenuRow<Content: View>: View {
    @ObservedObject var navigator: MenuNavigator
    let item: MenuItemID
    var enabled = true
    let label: String
    @ViewBuilder let content: (_ highlighted: Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var highlighted: Bool { enabled && navigator.highlighted == item }

    var body: some View {
        Button { navigator.activate(item) } label: {
            content(highlighted)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(highlighted ? (contrast == .increased ? 0.18 : 0.08) : 0))
                )
                .animation(Motion.hover(reduceMotion), value: highlighted)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 6)
        .onHover { inside in
            if inside && enabled {
                navigator.highlighted = item
            } else if navigator.highlighted == item {
                navigator.highlighted = nil
            }
        }
        .accessibilityLabel(label)
    }
}

private struct AutomaticSwitchingRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigator: MenuNavigator

    var body: some View {
        let on = model.settings.automaticSwitching
        MenuRow(navigator: navigator, item: .automaticSwitching, label: "Automatic switching") { _ in
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Automatic switching")
                    if !on {
                        Text("Paused")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: model.binding(\.automaticSwitching))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(on ? "on" : "off")
    }
}

private struct DeviceSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigator: MenuNavigator
    let direction: Direction

    var body: some View {
        let current = model.current(direction)
        let expanded = navigator.expanded == direction
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(navigator: navigator, item: .section(direction), label: "\(direction.label): \(current?.displayName ?? "none")") { _ in
                HStack(spacing: 10) {
                    Image(systemName: current.map(deviceSymbol) ?? (direction == .input ? "mic" : "speaker.wave.2"))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(direction.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(current?.displayName ?? "None")
                            .lineLimit(1)
                            .help(current?.name ?? "")
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .accessibilityHint("Shows connected \(direction.lowercaseLabel) devices in priority order")

            if expanded {
                DeviceList(model: model, navigator: navigator, direction: direction)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

private struct DeviceList: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigator: MenuNavigator
    let direction: Direction
    private let visibleRows = 8

    var body: some View {
        let rows = model.menuRows(direction)
        Group {
            if rows.isEmpty {
                Text("No devices connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 42)
                    .padding(.vertical, 4)
            } else if rows.count > visibleRows {
                ScrollView { content(rows) }.frame(height: CGFloat(visibleRows) * 26)
            } else {
                content(rows)
            }
        }
        .padding(.bottom, 4)
    }

    private func content(_ rows: [DeviceRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                MenuRow(navigator: navigator, item: .device(direction, row.uid), enabled: row.isUsable, label: label(row)) { _ in
                    MenuDeviceLine(row: row)
                }
                .accessibilityHint("Selects it until it disconnects or a higher-ranked device connects")
            }
        }
    }

    private func label(_ row: DeviceRow) -> String {
        var parts = [row.displayName, "rank \(row.rank)"]
        if row.isDefault { parts.append("in use") }
        if !row.isUsable { parts.append("not ready") }
        if row.isAvoided { parts.append("avoided") }
        if row.isManualPick { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }
}

private struct MenuDeviceLine: View, Equatable {
    let row: DeviceRow

    var body: some View {
        HStack(spacing: 8) {
            Text("\(row.rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)
            Text(row.displayName)
                .lineLimit(1)
                .foregroundStyle(row.isUsable ? .primary : .secondary)
                .help(row.name)
            Spacer(minLength: 4)
            if !row.isUsable { Tag("Not ready") }
            if row.isAvoided { Tag("Avoided") }
            if row.isManualPick { PinnedBadge() }
            Image(systemName: "checkmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.prioAccent)
                .opacity(row.isDefault ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(true)
        }
        .padding(.leading, 10)
    }
}

private struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// Marks the manual pick with text, not color alone.
struct PinnedBadge: View {
    var body: some View {
        // Text stays primary: the teal accent is below 4.5:1 for small text on light backgrounds.
        Text("Pinned")
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.prioAccent.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Color.prioAccent, lineWidth: 1))
            .help("You picked this device. Prio keeps it until it disconnects or a higher-ranked device connects.")
            .accessibilityLabel("Pinned")
    }
}

private struct LastActionView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigator: MenuNavigator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let action = model.lastAction {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.sentence)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(relative(action.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if model.canUndo {
                        Button("Undo") { navigator.activate(.undo) }
                            .controlSize(.small)
                            .accessibilityHint("Restores the previous device and pins it")
                    }
                }
                .id(action.id)
                .transition(.opacity.combined(with: .offset(y: -4)))
            } else {
                Text("No recent changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Direction.allCases, id: \.self) { d in
                if model.loopActive[d] == true {
                    Text("Not correcting \(d.lowercaseLabel): something keeps changing it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .animation(Motion.standard(reduceMotion), value: model.lastAction?.id)
    }

    /// Recomputed when the popover opens; no timers while idle (R9).
    private func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct CommandLabel: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}
