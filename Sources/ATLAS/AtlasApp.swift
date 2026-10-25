import AtlasCore
import SwiftUI

@main
struct AtlasApp: App {
    @State private var model = AppModel()

    init() {
        // `open -n ATLAS.app --args --diagnose` records what macOS reports for this exact app identity, then exits.
        if CommandLine.arguments.contains("--diagnose") { PermissionDiagnostics.writeAndExit() }
    }

    var body: some Scene {
        WindowGroup("ATLAS", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Analyze Now") { model.runManualAnalysis() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().environment(model).frame(width: 720, height: 560)
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.settings.trackingEnabled
                  ? (model.settings.privateMode ? "eye.slash.circle" : (model.agentBusy ? "sparkles" : "record.circle"))
                  : "pause.circle")
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case today = "Today", timeline = "Timeline", checkins = "Check-ins", reports = "Reports"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .today: "sun.max"
        case .timeline: "list.bullet.below.rectangle"
        case .checkins: "text.bubble"
        case .reports: "chart.bar.xaxis"
        }
    }
}

/// Custom window shell: an inset sidebar panel beside a scrolling content column.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: AppSection = DemoData.startSection ?? .today

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section)
                .frame(width: 236)
            Group {
                switch section {
                case .today: DashboardView(goTo: { section = $0 })
                case .timeline: TimelineView()
                case .checkins: CheckinsView()
                case .reports: ReportsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .tint(Theme.ink)
        .sheet(isPresented: Binding(get: { model.showOnboarding }, set: { model.showOnboarding = $0 })) {
            OnboardingView().environment(model)
        }
        .overlay(alignment: .bottom) {
            if let err = model.lastError ?? model.startupError {
                ErrorBanner(message: err) { model.lastError = nil; model.startupError = nil }.padding()
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var section: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("ATLAS").font(.system(size: 15, weight: .bold)).tracking(1.2).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.top, 52) // header band holding the window buttons
            .padding(.bottom, 24)

            ForEach(AppSection.allCases) { s in
                SidebarItem(section: s, selected: section == s,
                            badge: s == .checkins ? model.pendingActions.count : 0) { section = s }
            }

            Spacer()
            TrackingControl()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
    }
}

struct SidebarItem: View {
    var section: AppSection
    var selected: Bool
    var badge: Int
    var action: () -> Void
    @State private var hover = false

    private var shortcut: String { "⌘\(AppSection.allCases.firstIndex(of: section)! + 1)" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                Text(section.rawValue).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                Spacer()
                Text(shortcut).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary).opacity(selected || hover ? 1 : 0.6)
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.mixed.opacity(0.18), in: Capsule()).foregroundStyle(Theme.mixed)
                }
            }
            .foregroundStyle(selected ? Theme.ink : Theme.inkSecondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.selection)
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                } else if hover {
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.track)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut(KeyEquivalent(Character(String(AppSection.allCases.firstIndex(of: section)! + 1))), modifiers: .command)
    }
}

/// Bottom of the sidebar: tracking state with its switch, agent state, settings.
struct TrackingControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.settings.trackingEnabled
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(on ? (model.settings.privateMode ? Theme.mixed : Theme.live) : Theme.inkTertiary)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(on ? (model.settings.privateMode ? "Private mode" : "Tracking") : "Paused")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(model.agentBusy ? "Analyzing…" : "\(Fmt.duration(model.todayStateTotals.active)) active today")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { v in model.update { $0.trackingEnabled = v } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(on ? "Pause tracking" : "Resume tracking")
            }
            let degraded = model.health.filter { $0.level == .degraded }.count
            HStack {
                if degraded > 0 {
                    Button { model.showOnboarding = true } label: {
                        Label("\(degraded) source\(degraded == 1 ? "" : "s") limited", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.mixed)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(Theme.inkSecondary)
                    .help("Settings")
            }
            .font(.system(size: 11.5, weight: .medium))
        }
        .padding(12)
        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ErrorBanner: View {
    var message: String
    var dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 640)
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.settings.trackingEnabled ? (model.settings.privateMode ? "Tracking (private mode)" : "Tracking") : "Tracking paused")
        if let c = model.current, model.settings.trackingEnabled {
            Text("Now: \(c.displayLabel) · \(c.classification.category.displayName)")
        }
        Text("Next analysis in \(Fmt.duration(model.awakeRemaining)) of awake time")
        if !model.pendingActions.isEmpty { Text("\(model.pendingActions.count) change(s) awaiting approval") }
        Divider()
        Button(model.settings.trackingEnabled ? "Pause Tracking" : "Resume Tracking") { model.update { $0.trackingEnabled.toggle() } }
        Button(model.settings.privateMode ? "Leave Private Mode" : "Private Mode") { model.update { $0.privateMode.toggle() } }
        Button("Analyze Now") { model.runManualAnalysis() }
        Divider()
        Button("Open ATLAS") { openWindow(id: "main"); NSApp.activate() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit ATLAS") { NSApp.terminate(nil) }
    }
}
