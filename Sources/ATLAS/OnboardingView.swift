import AtlasCore
import AtlasPlatform
import SwiftUI

/// First-run (and "Fix permissions") sheet. Every permission ATLAS uses is requested here explicitly,
/// with live status, because macOS shows each system prompt only once.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.permissions
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up ATLAS").font(.title2.weight(.semibold))
                Text("ATLAS only tracks. Everything stays on this Mac; nothing is recorded from excluded apps or sites.")
                    .foregroundStyle(.secondary)
            }

            PermissionRow(title: "Window titles", detail: "Accessibility lets ATLAS read the focused window's title (e.g. which document or video). Toggle ATLAS on in the list that opens.",
                          state: p.accessibility ? .granted : .missing, actionTitle: "Open Settings…") { model.requestAccessibility() }
            if model.accessibilityLooksStale {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Already switched on but still not granted?", systemImage: "info.circle").font(.callout.weight(.semibold))
                    Text("The switch in System Settings is what counts. If a leftover macOS dialog is still asking for access, dismiss it; that doesn't undo the switch. Still not granted after that? The entry may belong to an older ATLAS build: select ATLAS in the list, click − to remove it, then click Open Settings… here and switch the new entry on (or run the reset command in Terminal).")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy reset command") { model.copyAccessibilityResetCommand() }
                        Button("Relaunch ATLAS") { model.relaunch() }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 34)
            }

            PermissionRow(title: "Chrome tabs", detail: p.chromeInstalled
                          ? "Lets ATLAS read the active tab's address and title, so YouTube, X or docs are told apart. macOS will ask “ATLAS wants to control Google Chrome”."
                          : "Google Chrome isn't installed.",
                          state: p.chromeAutomation == .granted || p.chromeExtension ? .granted : p.chromeAutomation == .denied ? .denied : .missing,
                          actionTitle: p.chromeAutomation == .denied ? "Open Settings…" : "Allow…", enabled: p.chromeInstalled) {
                if p.chromeAutomation == .denied {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                } else {
                    model.requestChromeAccess()
                }
            }

            PermissionRow(title: "Chrome extension (optional, more precise)",
                          detail: "Event-driven, knows when audio is playing, and handles incognito correctly. Chrome only allows loading it by hand: in the Chrome tab that opens, turn on Developer mode, click “Load unpacked”, and pick the highlighted chromium folder. ATLAS has already registered its helper.",
                          state: p.chromeExtension ? .granted : .optional, actionTitle: "Install…", enabled: p.chromeInstalled) {
                model.installChromeExtension()
            }

            PermissionRow(title: "Calendar", detail: "Read your events for reports (ATLAS never edits events it didn't create).",
                          state: p.calendar == .granted ? .granted : p.calendar == .denied ? .denied : .missing,
                          actionTitle: p.calendar == .denied ? "Open Settings…" : "Allow…") {
                if p.calendar == .denied {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                } else {
                    model.requestCalendarAccess()
                }
            }

            PermissionRow(title: "Notifications", detail: "Lock-screen-safe alerts. Check-in feedback arrives through the Claude app.",
                          state: p.notifications ? .granted : .optional, actionTitle: "Allow…") { model.requestNotifications() }

            PermissionRow(title: "Claude", detail: model.claudeCodePath == nil
                              ? "Optional. Install Claude Code and sign in with your subscription for scheduled check-ins. Tracking works without it."
                              : "Scheduled check-ins run with your Claude subscription and read ATLAS through the atlas MCP server.",
                          state: model.mcpConnected == true ? .granted : .optional,
                          actionTitle: model.claudeCodePath == nil ? nil : "Connect…") {
                Task { await model.connectMCP() }
            }

            HStack {
                Text("Status updates automatically as you grant access.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.finishOnboarding() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600)
        .task { await model.refreshPermissions() }
    }
}

struct PermissionRow: View {
    enum State { case granted, missing, denied, optional }
    var title: String
    var detail: String
    var state: State
    var actionTitle: String?
    var enabled = true
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state != .granted, let actionTitle {
                Button(actionTitle, action: action).disabled(!enabled)
            } else if state == .granted {
                Text("Granted").font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
        }
    }

    private var icon: String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .denied: "xmark.octagon.fill"
        case .optional: "circle.dashed"
        }
    }

    private var color: Color {
        switch state {
        case .granted: .green
        case .missing: .orange
        case .denied: .red
        case .optional: .secondary
        }
    }
}

struct VerdictChip: View {
    var verdict: String?
    var body: some View {
        let (text, color): (String, Color) = switch verdict {
        case "on_track": ("On track", .green)
        case "mixed": ("Mixed", .orange)
        case "off_track": ("Off track", .red)
        default: ("Check-in", .secondary)
        }
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}
