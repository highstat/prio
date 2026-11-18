import AppKit
import PrioCore
import SwiftUI

/// F18: general settings, helper text, diagnostics and about.
struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @ViewState private var showingDiagnostics = false

    var body: some View {
        Form {
            Section {
                Toggle("Automatic switching", isOn: model.binding(\.automaticSwitching))
                Toggle("Launch at login", isOn: model.launchAtLoginBinding)
                    .disabled(model.loginItemState == .unavailable)
                if model.loginItemState == .needsApproval {
                    HStack {
                        Text("Allow Prio in Login Items to finish.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { LoginItem.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                if model.loginItemState == .unavailable {
                    Caption("Available when Prio runs from its app bundle.")
                }
                if let error = model.loginItemError {
                    Caption(error)
                }
            }

            Section("Notifications") {
                Toggle("Show notifications", isOn: model.binding(\.notificationsEnabled))
                Toggle("Notify on every switch", isOn: model.binding(\.notifyOnEverySwitch))
                    .disabled(!model.settings.notificationsEnabled)
                Caption("Prio always tells you when it reverts a change, uses an avoided device, stops correcting, or fails to switch.")
            }

            Section("Changes made outside Prio") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Respect output changes made outside Prio", isOn: model.binding(\.respectOutputChanges))
                    Caption("If you pick an output in Control Center or System Settings, Prio keeps it.")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Respect input changes made outside Prio", isOn: model.binding(\.respectInputChanges))
                    Caption("Off: Prio switches the microphone back. macOS often moves it to a Bluetooth headset on its own.")
                }
            }

            Section("Bluetooth headphones keep connecting to this Mac?") {
                HStack(alignment: .center) {
                    Caption("Whether a device connects on its own is a per-device setting in macOS Bluetooth settings.")
                    Spacer()
                    Button("Open Bluetooth Settings…") { openBluetoothSettings() }
                }
            }

            Section("Diagnostics") {
                HStack {
                    Caption("A plain-text report for bug reports. You see it before anything is copied. Nothing is sent anywhere.")
                    Spacer()
                    Button("Copy Diagnostics…") { showingDiagnostics = true }
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prio \(AppInfo.version)")
                        .font(.headline)
                    Caption("Free and open source under the MIT License. Copyright 2026 Prio contributors.")
                    Button("Source code: \(AppInfo.sourceURLText)") {
                        NSWorkspace.shared.open(AppInfo.sourceURL)
                    }
                    .buttonStyle(.link)
                    .accessibilityHint("Opens the project page in your browser")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 640)
        .tint(.prioAccent)
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsSheet(model: model, isPresented: $showingDiagnostics)
        }
        .onAppear { model.refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItem()
        }
    }

    private func openBluetoothSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.BluetoothSettings",
            "x-apple.systempreferences:com.apple.preferences.Bluetooth",
        ]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// F19: preview, then copy on confirmation.
struct DiagnosticsSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @ViewState private var includeNames = false

    var body: some View {
        let report = model.diagnostics(includeNames: includeNames)
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.headline)
            Text("Check the report below. Copy puts it on the clipboard; Prio never sends it anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            .accessibilityLabel("Report preview")
            Toggle("Include device names", isOn: $includeNames)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(report, forType: .string)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .tint(.prioAccent)
    }
}
