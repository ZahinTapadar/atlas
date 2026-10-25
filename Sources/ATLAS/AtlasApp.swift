import AtlasCore
import SwiftUI

@main
struct AtlasApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("ATLAS", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
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
    case dashboard = "Dashboard", timeline = "Timeline", plan = "Plan", agent = "Agent", reports = "Reports"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .timeline: "list.bullet.rectangle"
        case .plan: "checklist"
        case .agent: "sparkles"
        case .reports: "chart.bar.xaxis"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: AppSection = .dashboard

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .badge(s == .agent ? model.pendingActions.count : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { TrackingStatusFooter().padding(10) }
        } detail: {
            Group {
                switch section {
                case .dashboard: DashboardView()
                case .timeline: TimelineView()
                case .plan: PlanView()
                case .agent: AgentView()
                case .reports: ReportsView()
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    if model.agentBusy { ProgressView().controlSize(.small).help("Agent is analyzing a window") }
                    Button { model.runManualAnalysis() } label: { Label("Analyze Now", systemImage: "sparkles") }
                        .help("Analyze activity since the current window started (does not change window boundaries)")
                    Toggle(isOn: Binding(get: { model.settings.trackingEnabled },
                                         set: { v in model.update { $0.trackingEnabled = v } })) {
                        Label("Tracking", systemImage: model.settings.trackingEnabled ? "record.circle.fill" : "pause.circle")
                    }
                    .toggleStyle(.button)
                    .help(model.settings.trackingEnabled ? "Pause tracking" : "Resume tracking")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let err = model.lastError ?? model.startupError {
                ErrorBanner(message: err) { model.lastError = nil; model.startupError = nil }.padding()
            }
        }
    }
}

struct TrackingStatusFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(level: model.settings.trackingEnabled ? (model.settings.privateMode ? .degraded : .ok) : .off)
                Text(model.settings.trackingEnabled ? (model.settings.privateMode ? "Private mode" : "Tracking") : "Paused")
                    .font(.caption.weight(.semibold))
            }
            HStack(spacing: 6) {
                StatusDot(level: model.agentBusy ? .ok : .off)
                Text(model.agentBusy ? "Agent analyzing…" : "Agent idle").font(.caption).foregroundStyle(.secondary)
            }
            let degraded = model.health.filter { $0.level == .degraded }.count
            if degraded > 0 {
                Text("\(degraded) tracking source\(degraded == 1 ? "" : "s") degraded").font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
