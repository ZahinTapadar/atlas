import AtlasCore
import AtlasPlatform
import SwiftUI

/// First-run setup (also "Permissions & setup…" in Settings). Tracking needs the permissions; check-ins
/// need Claude connected, a check-in schedule and an email address. Every row shows its live status and
/// the one action that completes it, because macOS shows each system prompt only once.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var appPassword = ""

    var body: some View {
        let p = model.permissions
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up ATLAS").font(.title2.weight(.semibold))
                Text(model.setupStepsRemaining == 0 ? "Everything is set up." : "\(model.setupStepsRemaining) essential step\(model.setupStepsRemaining == 1 ? "" : "s") left. Everything you track stays on this Mac.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 14)

            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Color.clear.frame(height: 0).id("top")
                    group("Tracking", "What ATLAS needs to see what you're doing.")
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


                    group("Claude check-ins", "Every three hours Claude reads ATLAS, compares it with your plan and tells you whether you're on track. Uses your Claude subscription; tracking works without it.")

                    PermissionRow(title: "Claude Code", detail: model.claudeCodePath == nil
                                  ? "Install Claude Code, then sign in with your Claude Pro or Max plan."
                                  : (model.claudeCodeAuth?.isSubscription == true ? "Installed and signed in with your subscription." : "Installed. Sign in with your Claude subscription: run claude auth login in Terminal."),
                                  state: model.claudeCodeAuth?.isSubscription == true ? .granted : .missing,
                                  actionTitle: model.claudeCodePath == nil ? "Get Claude Code…" : "Check again", doneLabel: "Ready") {
                        if model.claudeCodePath == nil { NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs")!) }
                        else { Task { await model.refresh(); await model.refreshSetup() } }
                    }

                    PermissionRow(title: "Connect ATLAS to Claude", detail: "Lets Claude read your activity summaries and record check-ins (the atlas MCP server).",
                                  state: model.mcpConnected == true ? .granted : .missing,
                                  actionTitle: "Connect", enabled: model.claudeCodePath != nil, doneLabel: "Connected") {
                        Task { await model.connectMCP() }
                    }

                    PermissionRow(title: "Check-in schedule", detail: model.checkinTaskInstalled
                                  ? "Your check-in task is scheduled for 9, 12, 15, 18 and 21."
                                  : "Copy the request, paste it into a new chat in the Claude app, and send it. Claude creates the check-in task (9, 12, 15, 18 and 21) and runs a first one.",
                                  state: model.checkinTaskInstalled ? .granted : .missing,
                                  actionTitle: "Copy request and open Claude", enabled: model.mcpConnected == true, doneLabel: "Scheduled") {
                        model.copyCheckinRequest()
                        model.openClaude()
                    }

                    group("Email", "Each check-in arrives as an email, so it reaches your phone.")
                    emailRows

                    group("Optional", "Each makes check-ins smarter.")

                    PermissionRow(title: "Things 3", detail: model.thingsInstalled
                                  ? "Check-ins compare your Things Today list with what you did, tick off finished to-dos and add next steps. macOS asks to let ATLAS control Things the first time."
                                  : "If you plan in Things 3, install it and check-ins will use your Today list.",
                                  state: model.thingsInstalled && model.thingsProblem == "" ? .granted : .optional,
                                  actionTitle: model.thingsInstalled ? "Allow…" : nil, enabled: model.thingsInstalled, doneLabel: "Connected") {
                        Task { await model.refreshThings() }
                    }

            PermissionRow(title: "Chrome extension (optional, more precise)",
                          detail: "Event-driven, knows when audio is playing, and handles incognito correctly. Chrome only allows loading it by hand: in the Chrome tab that opens, turn on Developer mode, click “Load unpacked”, and pick the highlighted chromium folder. ATLAS has already registered its helper.",
                          state: p.chromeExtension ? .granted : .optional, actionTitle: "Install…", enabled: p.chromeInstalled) {
                model.installChromeExtension()
            }


                    PermissionRow(title: "Calendar in Claude", detail: "Connect Google Calendar in the Claude app (Settings → Connectors) and check-ins log what you did and book your next step with a reminder.",
                                  state: .optional, actionTitle: nil) {}
                }
                .padding(.horizontal, 22).padding(.bottom, 16)
            }
            .task {
                // macOS focuses the email field, which scrolls the sheet; start at the top.
                try? await Task.sleep(for: .milliseconds(300))
                scroller.scrollTo("top", anchor: .top)
            }
            }

            Divider()
            HStack {
                Text("Status updates as you go.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.setupStepsRemaining == 0 ? "Done" : "Finish later") { model.finishOnboarding() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 640, height: 720)
        .task {
            email = model.notifyEmail
            await model.refreshPermissions()
            await model.refreshSetup()
        }
        .task {
            // The check-in task is created in Claude, outside ATLAS: notice it appearing (a file check, cheap).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                model.checkinTaskInstalled = CheckinTask.isInstalled()
            }
        }
    }

    private func group(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    @ViewBuilder private var emailRows: some View {
        let html = MailAccount.supportsHTML(email)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.notifyEmail.isEmpty ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.notifyEmail.isEmpty ? .orange : .green).font(.title3).frame(width: 22)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where check-ins go").font(.headline)
                    TextField("you@gmail.com", text: $email).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    if html {
                        Text("For the designed email (charts, to-dos, scorecard), ATLAS sends through your own account with an app password. Without one, check-ins arrive as plain text through Mail.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            SecureField(model.emailHTMLReady ? "Saved. Paste a new one to replace it" : "App password", text: $appPassword)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                            if let page = MailAccount.appPasswordPage(for: email) {
                                Button("Get one…") { NSWorkspace.shared.open(page) }
                            }
                        }
                    } else if !email.isEmpty {
                        Text("Check-ins go out as plain text through the Mail app (designed emails need a Gmail or iCloud address).")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button(model.emailSetupBusy ? "Sending…" : "Save and send a test") {
                            let pw = appPassword
                            appPassword = ""
                            Task { await model.setUpEmail(address: email, appPassword: pw) }
                        }
                        .disabled(model.emailSetupBusy || email.isEmpty)
                        if let msg = model.emailSetupMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

struct PermissionRow: View {
    enum State { case granted, missing, denied, optional }
    var title: String
    var detail: String
    var state: State
    var actionTitle: String?
    var enabled = true
    var doneLabel = "Granted"
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
                Text(doneLabel).font(.caption.weight(.semibold)).foregroundStyle(.green)
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
