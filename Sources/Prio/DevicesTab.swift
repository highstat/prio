import AppKit
import PrioCore
import SwiftUI

/// F17: ranked lists with reordering, avoid checkboxes and Forget.
struct DevicesTab: View {
    @ObservedObject var model: AppModel
    @ViewState private var direction: Direction
    @ViewState private var selection: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func animate(_ edit: () -> Void) {
        withAnimation(Motion.standard(reduceMotion), edit)
    }

    init(model: AppModel, direction: Direction = .output) {
        self.model = model
        _direction = ViewState(initialValue: direction)
    }

    private var rows: [DeviceRow] { model.rows(direction) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("List", selection: $direction) {
                Text("Input").tag(Direction.input)
                Text("Output").tag(Direction.output)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Device list")
            .onChange(of: direction) { _ in selection = nil }

            List(selection: $selection) {
                ForEach(rows) { row in
                    DeviceSettingsRow(model: model, row: row)
                        .tag(row.uid)
                        .contextMenu { contextMenu(for: row) }
                }
                .onMove { source, destination in
                    animate { model.engine.move(direction, fromOffsets: source, toOffset: destination) }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .overlay {
                if rows.isEmpty {
                    Text("No devices yet")
                        .foregroundStyle(.secondary)
                }
            }
            .background(keyboardShortcuts)

            Text("Drag to reorder, or press ⌥⌘↑ and ⌥⌘↓. Untick a device to use it only as a last resort.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 600, height: 440)
        .tint(.prioAccent)
    }

    @ViewBuilder
    private func contextMenu(for row: DeviceRow) -> some View {
        Button("Move Up") { animate { model.engine.moveUp(row.uid, direction) } }
            .disabled(row.rank == 1)
        Button("Move Down") { animate { model.engine.moveDown(row.uid, direction) } }
            .disabled(row.rank == rows.count)
        Button("Move to Top") { animate { model.engine.moveToTop(row.uid, direction) } }
            .disabled(row.rank == 1)
        if !row.isConnected {
            Divider()
            Button("Forget Device") {
                model.engine.forget(row.uid, direction)
                if selection == row.uid { selection = nil }
            }
        }
    }

    /// Invisible buttons that carry the ⌥⌘↑ / ⌥⌘↓ shortcuts for the selected row.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Move Up") {
                if let uid = selection { animate { model.engine.moveUp(uid, direction) } }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move Down") {
                if let uid = selection { animate { model.engine.moveDown(uid, direction) } }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct DeviceSettingsRow: View {
    @ObservedObject var model: AppModel
    let row: DeviceRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func animate(_ edit: () -> Void) {
        withAnimation(Motion.standard(reduceMotion), edit)
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("\(row.rank)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
                Image(systemName: deviceSymbol(row))
                    .frame(width: 20)
                    .foregroundStyle(row.isConnected ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(row.isConnected ? .primary : .secondary)
                            .help(row.name)
                        if row.isManualPick { PinnedBadge() }
                    }
                    Text(row.transport.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StatusLabel(status: row.status)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: row.status)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilitySummary)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Move Up") { animate { model.engine.moveUp(row.uid, row.direction) } }
            .accessibilityAction(named: "Move Down") { animate { model.engine.moveDown(row.uid, row.direction) } }
            .accessibilityAction(named: "Move to Top") { animate { model.engine.moveToTop(row.uid, row.direction) } }

            Toggle("Use automatically", isOn: Binding(
                get: { !row.isAvoided },
                set: { model.engine.setAvoided(row.uid, row.direction, !$0) }
            ))
            .toggleStyle(.checkbox)
            .help("When off, Prio skips this device while another one is connected. It is still used as a last resort.")
            .accessibilityLabel("Use \(row.displayName) automatically")
        }
        .padding(.vertical, 3)
    }
}

/// Status as text plus symbol; color is never the only signal.
private struct StatusLabel: View {
    let status: DeviceRow.Status

    var body: some View {
        HStack(spacing: 4) {
            switch status {
            case .inUse:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.prioAccent)
                Text("In use")
            case .connected:
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
                Text("Connected").foregroundStyle(.secondary)
            case .notConnected:
                Image(systemName: "circle").font(.system(size: 6)).foregroundStyle(.tertiary)
                Text("Not connected").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .id(status)
        .transition(.opacity)
        .frame(width: 118, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
