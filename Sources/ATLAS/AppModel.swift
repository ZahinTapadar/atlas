import AppKit
import AtlasCore
import AtlasPlatform
import Foundation
import Observation

struct HealthItem: Identifiable, Hashable {
    enum Level { case ok, degraded, off }
    var id: String { name }
    var name: String
    var level: Level
    var detail: String
}

/// App-wide state and intents. Owns the tracker (System A) and the agent (System B) and keeps
/// them independent: the tracker never waits on the agent, and the agent only runs per window.
@MainActor
@Observable
final class AppModel {
    // Persistent services
    let store: AtlasStore
    let tracker: TrackerCore
    let coordinator: AnalysisCoordinator
    let secrets = KeychainStore()
    let eventKit = EventKitConnector()
    private var workspace: WorkspaceMonitor!
    private var idle: IdleMonitor!
    private var titles: WindowTitleObserver!
    private var browserProbe: BrowserScriptProbe!
    private var tickTimer: Timer?
    private var deadlineTimer: Timer?
    private var lastPurge = Date.distantPast
    private var lastSessionRebuild = Date.distantPast

    // UI state
    var settings: AtlasSettings
    var current: ActivityEvent?
    var todayEvents: [ActivityEvent] = []
    var todaySessions: [ActivitySession] = []
    var openWindow: AnalysisWindow?
    var windows: [AnalysisWindow] = []
    var pendingActions: [AgentAction] = []
    var recentActions: [AgentAction] = []
    var planItems: [PlanItem] = []
    var rules: [ClassificationRule] = []
    var health: [HealthItem] = []
    var requestLog: [AtlasStore.RequestLogEntry] = []
    var dailySummaries: [DailySummary] = []
    var calendarStatus: ConnectorStatus = .notAuthorized("Not checked")
    var agentBusy = false
    var hasAPIKey = false
    var checkins: [AtlasStore.Checkin] = []
    var notifyEmail = ""
    var thingsItems: [Things.Item] = []
    /// nil until the first read; otherwise why Things could not be read ("" when it could).
    var thingsProblem: String?
    var todoReasons: [AtlasStore.TodoReason] = []
    var showOnboarding = false
    var permissions = PermissionStatus()
    private var permissionTimer: Timer?
    var claudeCodeAuth: ClaudeCodeProvider.AuthStatus?
    var claudeCodePath: String?
    /// Whether Claude has the `atlas` MCP server pointing at this copy of ATLAS (nil until checked).
    var mcpConnected: Bool?
    var lastError: String?
    var startupError: String?

    static func openStore() -> (AtlasStore, String?) {
        if DemoData.isEnabled { return (try! AtlasStore.inMemory(), nil) }
        let dir = AtlasStore.defaultDirectory
        let path = dir.appendingPathComponent("atlas.sqlite").path
        do {
            let s = try AtlasStore(path: path)
            return (s, nil)
        } catch {
            // Corrupt or newer database: keep the file for recovery and start fresh rather than crash.
            let moved = path + ".unreadable-\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.moveItem(atPath: path, toPath: moved)
            if let s = try? AtlasStore(path: path) {
                return (s, "The database could not be opened and was set aside at \(moved). (\(error))")
            }
            return (try! AtlasStore.inMemory(), "Storage unavailable; running in memory only. (\(error))")
        }
    }

    init() {
        let (store, err) = Self.openStore()
        self.store = store
        self.startupError = err
        let settings = AtlasSettings()
        self.settings = settings
        self.tracker = TrackerCore(store: store, settings: settings, rules: [])
        // Re-read the backend choice per analysis so a settings change takes effect without a restart.
        let provider = BackendSelector { [store] in
            let s = (try? await store.loadSettings()) ?? AtlasSettings()
            switch s.agentBackend {
            case .claudeSubscription: return ClaudeCodeProvider(executablePath: s.claudeExecutablePath)
            case .anthropicAPI: return ClaudeProvider(secrets: KeychainStore())
            }
        }
        let ek = eventKit
        self.coordinator = AnalysisCoordinator(store: store, provider: provider, connectors: [ek],
                                               health: { await AppModel.healthNotesForAgent(ek) })
        self.workspace = WorkspaceMonitor { [weak self] o, d in self?.observe(o, at: d) }
        self.idle = IdleMonitor(threshold: settings.idleThresholdSeconds) { [weak self] o, d in self?.observe(o, at: d) }
        self.titles = WindowTitleObserver { [weak self] o, d in self?.observe(o, at: d) }
        self.browserProbe = BrowserScriptProbe { [weak self] o, d in self?.observe(o, at: d) }
        if DemoData.isEnabled { Task { await self.bootDemo() } } else { Task { await self.boot() } }
    }

    /// `--demo`: synthetic data in memory, no tracking, no permissions, no prompts.
    private func bootDemo() async {
        await DemoData.seed(into: store)
        var s = AtlasSettings()
        s.onboardingCompleted = true
        s.notificationsEnabled = false
        settings = s
        await refresh()
        DemoData.prepareWindow()
    }

    nonisolated static func healthNotesForAgent(_ ek: EventKitConnector) async -> [String] {
        var notes: [String] = []
        if !AXIsProcessTrusted() { notes.append("Window titles unavailable (Accessibility not granted): app-level tracking only") }
        if let seen = BrowserInbox.lastActivity(), Date().timeIntervalSince(seen) < 6 * 3600 {} else {
            notes.append("Browser extension not reporting: browser time is uncategorized")
        }
        return notes
    }

    // MARK: - Lifecycle

    private func boot() async {
        do {
            settings = try await store.loadSettings()
            rules = try await store.rules()
            await tracker.updateSettings(settings)
            await tracker.updateRules(rules)
        } catch { lastError = "Could not load settings: \(error)" }
        hasAPIKey = !(secrets.read(ClaudeProvider.apiKeyAccount) ?? "").isEmpty
        await coordinator.setHandler { [weak self] e in Task { @MainActor in self?.handle(e) } }
        try? await coordinator.recoverAfterRestart()
        if settings.notificationsEnabled { _ = await NotificationService.requestAuthorization() }
        try? FileManager.default.createDirectory(at: BrowserInbox.defaultDirectory, withIntermediateDirectories: true)
        registerBrowserHelper()
        // Re-apply the classifier to recent history so improvements fix past "unclassified" time too.
        _ = try? await tracker.reclassify(from: Date().addingTimeInterval(-14 * 86400), to: Date())
        if settings.trackingEnabled { await startTracking() }
        await refreshPermissions()
        if !settings.onboardingCompleted || !permissions.accessibility {
            showOnboarding = true
            // Ask up front, but only once ever: repeated requests queue duplicate system dialogs.
            if !permissions.accessibility && !settings.accessibilityPromptShown {
                WindowTitleObserver.requestTrust()
                update { $0.accessibilityPromptShown = true }
            }
            if permissions.calendar == .notDetermined { _ = await eventKit.requestAccess() }
        }
        watchPermissions()
        await refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    func startTracking() async {
        guard !(await tracker.isRunning) else { return }
        let front = WorkspaceMonitor.frontmostApp()
        do { try await tracker.start(at: Date(), frontmost: front) } catch { lastError = "Tracker failed to start: \(error)" }
        workspace.start()
        idle.threshold = settings.idleThresholdSeconds
        idle.start()
        configureTitleObserver()
        titles.follow(app: front)
        browserProbe.enabled = settings.browserAutomationEnabled && !settings.privateMode
        browserProbe.frontmostChanged(to: front?.bundleID)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: TrackerCore.flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        tickTimer?.tolerance = 5
    }

    /// Registers the bundled native-messaging helper with installed Chromium browsers (fixed extension ID).
    private func registerBrowserHelper() {
        let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/atlas-nm-host").path
        guard FileManager.default.isExecutableFile(atPath: host) else { return }
        ChromeExtension.registerNativeHost(hostPath: host)
    }

    var bundledExtensionFolder: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Extensions/chromium")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func refreshPermissions() async {
        var p = PermissionStatus()
        p.accessibility = AXIsProcessTrusted()
        p.calendar = await eventKit.status() == .connected ? .granted : (calendarStatusNotDetermined() ? .notDetermined : .denied)
        p.chromeInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
        p.chromeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
        if p.chromeRunning {
            let st = BrowserScriptProbe.permissionStatus(bundleID: "com.google.Chrome")
            p.chromeAutomation = st == noErr ? .granted : st == -1744 ? .notDetermined : .denied
        }
        p.chromeExtension = BrowserInbox.lastActivity().map { Date().timeIntervalSince($0) < 6 * 3600 } ?? false
        p.notifications = await NotificationService.isAuthorized()
        let wasTrusted = permissions.accessibility
        permissions = p
        if p.accessibility && !wasTrusted {
            // Accessibility was just granted: start reading window titles without a relaunch.
            titles.follow(app: WorkspaceMonitor.frontmostApp())
        }
    }

    private func calendarStatusNotDetermined() -> Bool { EventKitConnector.isNotDetermined }

    /// Poll permission state only while something is missing (System Settings sends no notification).
    private func watchPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshPermissions()
                if self.permissions.accessibility && self.permissions.calendar != .notDetermined && !self.showOnboarding {
                    self.permissionTimer?.invalidate()
                }
            }
        }
    }

    /// When the user opened Accessibility settings; used to detect a stale entry that never takes effect.
    var accessibilityRequestedAt: Date?

    /// The toggle is on but the grant doesn't apply: the list entry belongs to an older (differently signed) build.
    var accessibilityLooksStale: Bool {
        guard !permissions.accessibility else { return false }
        // Show the help whenever setup was seen before (the user likely already toggled it) or 15 s after asking.
        if settings.onboardingCompleted { return true }
        guard let t = accessibilityRequestedAt else { return false }
        return Date().timeIntervalSince(t) > 15
    }

    func copyAccessibilityResetCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("tccutil reset Accessibility com.atlas.tracker", forType: .string)
    }

    func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        shutdown()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            // NSApp.terminate can be cancelled while a sheet is open, leaving two copies running; exit directly
            // (shutdown() already flushed the tracker).
            exit(0)
        }
    }

    func requestAccessibility() {
        accessibilityRequestedAt = Date()
        // Go straight to the list; don't stack another system prompt on top of an existing one.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        watchPermissions()
    }

    func requestChromeAccess() {
        if !permissions.chromeRunning, let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.openApplication(at: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
        Task.detached {
            // Blocks until the user answers the macOS prompt, so keep it off the main thread.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = BrowserScriptProbe.requestPermission(bundleID: "com.google.Chrome")
            await self.refreshPermissions()
        }
    }

    func installChromeExtension() {
        registerBrowserHelper()
        if let folder = bundledExtensionFolder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
           let url = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func requestNotifications() { Task { _ = await NotificationService.requestAuthorization(); await refreshPermissions() } }

    func finishOnboarding() {
        showOnboarding = false
        update { $0.onboardingCompleted = true }
    }

    func stopTracking() async {
        workspace.stop()
        idle.stop()
        titles.follow(app: nil)
        browserProbe.frontmostChanged(to: nil)
        tickTimer?.invalidate()
        deadlineTimer?.invalidate()
        await tracker.stop(at: Date())
        await refresh()
    }

    func shutdown() {
        // Best effort synchronous flush on quit.
        let t = tracker
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await t.stop(at: Date()); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }

    private func configureTitleObserver() {
        titles.enabled = settings.captureWindowTitles && !settings.privateMode
        titles.excludedBundleIDs = Set(settings.excludedBundleIDs.map { $0.lowercased() })
    }

    // MARK: - ActivitySignal plumbing

    private func observe(_ o: ActivitySignal, at date: Date) {
        if case .appActivated(let app) = o {
            titles.follow(app: app)
            browserProbe.frontmostChanged(to: app.bundleID)
        }
        if o == .systemDidWake || o == .screenUnlocked {
            titles.follow(app: WorkspaceMonitor.frontmostApp())
        }
        Task {
            await tracker.observe(o, at: date)
            await scheduleDeadline()
            current = await tracker.currentSnapshot(at: Date())
        }
    }

    private func scheduleDeadline() async {
        deadlineTimer?.invalidate()
        guard let d = await tracker.nextDeadline else { return }
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: max(1, d.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    func tick() async {
        let now = Date()
        if settings.browserExtensionEnabled {
            for m in BrowserInbox.drain() {
                if let (o, d) = BrowserInbox.observation(from: m) { await tracker.observe(o, at: min(d, now)) }
            }
        }
        do {
            let ready = try await tracker.tick(now: now)
            if !ready.isEmpty || now.timeIntervalSince(lastSessionRebuild) > 300 {
                let start = Calendar.current.startOfDay(for: now)
                try await tracker.rebuildSessions(from: start, to: now)
                lastSessionRebuild = now
            }
        } catch {
            lastError = "Tracking write failed: \(error)"
            AtlasLog.storage.error("tick failed: \(AtlasLog.redact("\(error)"), privacy: .public)")
        }
        if now.timeIntervalSince(lastPurge) > 86400 {
            lastPurge = now
            try? await store.purge(olderThan: now.addingTimeInterval(-Double(settings.retentionDays) * 86400),
                                   requestLogCutoff: now.addingTimeInterval(-Double(settings.requestLogRetentionDays) * 86400))
        }
        await scheduleDeadline()
        if settings.agentEnabled && settings.automaticWindowAnalysis {
            agentBusy = true
            await coordinator.processDueWindows()
            agentBusy = await coordinator.isProcessing
        } else {
            // Feedback comes from scheduled check-ins; close windows quietly instead of queueing them forever.
            for var w in (try? await store.windows(status: [.ready])) ?? [] where w.kind != .manual {
                w.status = .skipped
                w.lastError = "Automatic analysis is off (scheduled check-ins provide feedback)"
                try? await store.saveWindow(w)
            }
        }
        await refresh()
    }

    // MARK: - Claude MCP

    private var bundledCLI: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/atlasctl").path }

    /// Asks the Claude CLI whether `atlas` is registered and points at this app's atlasctl.
    func checkMCP() async {
        guard !DemoData.isEnabled, let claude = ClaudeCodeProvider.locateExecutable(override: settings.claudeExecutablePath) else {
            mcpConnected = nil; return
        }
        let cli = bundledCLI
        let out = await Task.detached { Self.run(claude, ["mcp", "get", "atlas"]) }.value
        mcpConnected = out.status == 0 && out.text.contains(cli)
    }

    /// Registers this app's atlasctl as the `atlas` MCP server for Claude (user scope), replacing an older entry.
    func connectMCP() async {
        guard let claude = ClaudeCodeProvider.locateExecutable(override: settings.claudeExecutablePath) else {
            lastError = "Claude Code isn't installed, so there's nothing to connect yet."; return
        }
        let cli = bundledCLI
        let result = await Task.detached { () -> (status: Int32, text: String) in
            _ = Self.run(claude, ["mcp", "remove", "--scope", "user", "atlas"])
            return Self.run(claude, ["mcp", "add", "--scope", "user", "atlas", "--", cli, "mcp"])
        }.value
        if result.status != 0 { lastError = "Could not connect Claude: \(result.text)" }
        await checkMCP()
    }

    nonisolated private static func run(_ exe: String, _ args: [String]) -> (status: Int32, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Things

    /// Re-reads Things' Today list (with checklists and project contents) and today's recorded reasons.
    func refreshThings() async {
        todoReasons = (try? await store.todoReasons(since: AtlasStore.dayKey())) ?? []
        if DemoData.isEnabled {
            thingsItems = DemoData.thingsItems
            thingsProblem = ""
            return
        }
        do {
            thingsItems = try await Task.detached(priority: .utility) { try Things.today() }.value
            thingsProblem = ""
        } catch {
            thingsProblem = error.localizedDescription
        }
    }

    func setThingsDone(_ id: String, _ done: Bool) async {
        func apply(_ items: inout [Things.Item]) {
            for i in items.indices {
                if items[i].id == id { items[i].status = done ? "completed" : "open" }
                for j in items[i].children.indices where items[i].children[j].id == id { items[i].children[j].done = done }
            }
        }
        apply(&thingsItems)
        if DemoData.isEnabled { return }
        do {
            try await Task.detached { try Things.setDone(id: id, done) }.value
        } catch {
            lastError = "Things: \(error.localizedDescription)"
        }
        await refreshThings()
    }

    func reason(for item: Things.Item) -> String? {
        todoReasons.first { $0.key == item.id || $0.title == item.title }?.reason
    }

    func setReason(for item: Things.Item, _ text: String) async {
        do {
            try await store.setTodoReason(key: item.id, title: item.title, reason: text)
            todoReasons = try await store.todoReasons(since: AtlasStore.dayKey())
        } catch { lastError = "Could not save the reason: \(error)" }
    }

    // MARK: - Refresh

    func refresh() async {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        do {
            todayEvents = try await store.events(from: start, to: now.addingTimeInterval(60))
            todaySessions = try await store.sessions(from: start, to: now)
            openWindow = try await store.openWindow()
            windows = try await store.recentWindows(limit: 40)
            pendingActions = try await store.pendingActions()
            recentActions = try await store.actions(limit: 100)
            planItems = try await store.planItems(includeClosed: true)
            requestLog = try await store.requestLog(limit: 100)
            dailySummaries = try await store.dailySummaries(limit: 30)
            rules = try await store.rules()
            checkins = try await store.checkins(limit: 30)
            notifyEmail = try await store.preference(AtlasStore.notifyEmailKey) ?? ""
        } catch { lastError = "Could not read data: \(error)" }
        announceNewCheckin()
        current = await tracker.currentSnapshot(at: now)
        if DemoData.isEnabled {
            current = todayEvents.max { $0.end < $1.end }
            health = []
            return
        }
        calendarStatus = await eventKit.status()
        hasAPIKey = !(secrets.read(ClaudeProvider.apiKeyAccount) ?? "").isEmpty
        if settings.agentBackend == .claudeSubscription {
            let cc = ClaudeCodeProvider(executablePath: settings.claudeExecutablePath)
            claudeCodePath = ClaudeCodeProvider.locateExecutable(override: settings.claudeExecutablePath)
            claudeCodeAuth = await cc.authStatus()
            if mcpConnected == nil { await checkMCP() }
        }
        health = await computeHealth()
    }

    private func computeHealth() async -> [HealthItem] {
        var h: [HealthItem] = []
        let running = await tracker.isRunning
        h.append(HealthItem(name: "Tracker", level: running ? .ok : .off,
                            detail: running ? (settings.privateMode ? "Running in private mode (no metadata)" : "Recording") : "Paused"))
        h.append(HealthItem(name: "Window titles", level: !settings.captureWindowTitles ? .off : (AXIsProcessTrusted() ? .ok : .degraded),
                            detail: !settings.captureWindowTitles ? "Disabled in settings"
                                : AXIsProcessTrusted() ? "Accessibility granted" : "Accessibility not granted — app-level only"))
        let seen = BrowserInbox.lastActivity()
        let ext = seen.map { Date().timeIntervalSince($0) < 6 * 3600 } ?? false
        let chromeDetail: String = switch permissions.chromeAutomation {
        case .granted: "Reading Chrome's active tab"
        case .denied: "Automation denied — allow in System Settings → Privacy → Automation"
        case .notDetermined: permissions.chromeRunning ? "Not yet allowed — click Fix permissions" : "Will ask when Chrome is open"
        }
        h.append(HealthItem(name: "Chrome tabs", level: !settings.browserAutomationEnabled ? .off
                                : (permissions.chromeAutomation == .granted || ext) ? .ok : .degraded,
                            detail: ext ? "Extension reporting" : chromeDetail))
        h.append(HealthItem(name: "Calendar", level: calendarStatus.isConnected ? .ok : .degraded, detail: calendarStatus.label))
        switch settings.agentBackend {
        case .claudeSubscription:
            let auth = claudeCodeAuth
            let detail = claudeCodePath == nil ? "Claude Code CLI not found — analyses will queue"
                : auth?.isSubscription == true ? "Claude Code signed in with your subscription"
                : auth?.loggedIn == true ? "Signed in with \(auth!.method), not a subscription — analyses will queue"
                : "Not signed in — run `claude auth login`"
            h.append(HealthItem(name: "Claude", level: auth?.isSubscription == true ? .ok : .degraded, detail: detail))
        case .anthropicAPI:
            h.append(HealthItem(name: "Claude API", level: hasAPIKey ? .ok : .degraded,
                                detail: hasAPIKey ? "Key in Keychain (billed per use)" : "No API key — analyses will queue"))
        }
        return h
    }

    private func handle(_ e: CoordinatorEvent) {
        switch e {
        case .analysisStarted:
            agentBusy = true
        case .analysisCompleted(let windowID, let headline, let topTask, let pending):
            agentBusy = false
            notifyReport(windowID: windowID, headline: headline, topTask: topTask, pending: pending)
        case .analysisFailed(_, let error, let willRetry):
            agentBusy = false
            lastError = "Analysis failed: \(error)\(willRetry ? " — will retry" : "")"
        case .awaitingReview(let id):
            if settings.notificationsEnabled && !NotificationService.isQuiet(settings.quietHours) {
                NotificationService.post(id: "review-\(id)", title: "ATLAS", body: "An activity window is ready for your review before sending.")
            }
        case .actionsChanged:
            break
        }
        Task { await refresh() }
    }

    private func notifyReport(windowID: String, headline: String, topTask: String, pending: Int) {
        guard settings.notificationsEnabled, !NotificationService.isQuiet(settings.quietHours) else { return }
        let body: String
        switch settings.notificationDetail {
        case .minimal:
            body = "Your activity report is ready." + (pending > 0 ? " \(pending) schedule change(s) need approval." : "")
        case .summary:
            // Category-level only: the model's headline can mention sites, so it is not used on the lock screen.
            let totals = TimeAccounting.totals(TimeAccounting.normalized(todayEvents, from: Calendar.current.startOfDay(for: Date()), to: Date()))
            let top = totals.sorted { $0.value.observed > $1.value.observed }.prefix(2)
                .map { "\($0.key.displayName) \(Int($0.value.observed / 60))m" }.joined(separator: ", ")
            var parts = ["Report ready."]
            if !top.isEmpty { parts.append("Today: \(top).") }
            if !topTask.isEmpty { parts.append("Next: \(String(topTask.prefix(60))).") }
            if pending > 0 { parts.append("\(pending) change(s) to approve.") }
            body = parts.joined(separator: " ")
        }
        NotificationService.post(id: "report-\(windowID)", title: "ATLAS", body: body)
    }

    // MARK: - Intents

    func saveSettings(_ s: AtlasSettings) {
        let old = settings
        settings = s
        Task {
            do { try await store.saveSettings(s) } catch { lastError = "Could not save settings: \(error)" }
            await tracker.updateSettings(s)
            idle.threshold = s.idleThresholdSeconds
            configureTitleObserver()
            browserProbe.enabled = s.browserAutomationEnabled && !s.privateMode
            if s.trackingEnabled != old.trackingEnabled {
                if s.trackingEnabled { await startTracking() } else { await stopTracking() }
            }
            if s.launchAtLogin != old.launchAtLogin {
                do { try LaunchAtLogin.set(s.launchAtLogin) } catch { lastError = "Launch at login requires the bundled app: \(error)" }
            }
            await refresh()
        }
    }

    func update(_ change: (inout AtlasSettings) -> Void) {
        var s = settings
        change(&s)
        saveSettings(s)
    }

    func setAPIKey(_ key: String) {
        do {
            try secrets.write(ClaudeProvider.apiKeyAccount, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
            hasAPIKey = !key.isEmpty
        } catch { lastError = "\(error)" }
        Task { await refresh() }
    }

    func requestCalendarAccess() {
        Task {
            _ = await eventKit.requestAccess()
            await refresh()
        }
    }

    func runManualAnalysis() {
        Task {
            agentBusy = true
            do { _ = try await coordinator.requestManualAnalysis() } catch { lastError = "\(error)" }
            agentBusy = false
            await refresh()
        }
    }

    func approveSend(windowID: String) {
        Task {
            agentBusy = true
            _ = await coordinator.process(windowID: windowID, userApproved: true)
            agentBusy = false
            await refresh()
        }
    }

    func retryWindow(_ id: String) {
        Task {
            if var w = try? await store.window(id: id), w.status == .failed || w.status == .abandoned {
                w.status = .failed
                w.attempts = 0
                w.nextAttemptAt = nil
                try? await store.saveWindow(w)
                _ = await coordinator.process(windowID: id, userApproved: false)
            }
            await refresh()
        }
    }

    func discard(windowID: String) { Task { try? await coordinator.discard(windowID: windowID); await refresh() } }
    func reanalyze(windowID: String) { Task { _ = try? await coordinator.reanalyze(windowID: windowID); await refresh() } }

    func approve(_ a: AgentAction, edited: ProposedChange? = nil) {
        Task { do { try await coordinator.approve(actionID: a.id, edited: edited) } catch { lastError = "\(error)" }; await refresh() }
    }
    func reject(_ a: AgentAction) { Task { try? await coordinator.reject(actionID: a.id); await refresh() } }
    func rollback(_ a: AgentAction) { Task { try? await coordinator.rollback(actionID: a.id); await refresh() } }
    func retry(_ a: AgentAction) { Task { try? await coordinator.retry(actionID: a.id); await refresh() } }

    func recategorize(_ e: ActivityEvent, to c: ActivityCategory, learn: CorrectionLearner.Scope?) {
        Task {
            do { try await tracker.recategorize(eventID: e.id, to: c, learn: learn) } catch { lastError = "\(error)" }
            await refresh()
        }
    }

    func split(_ e: ActivityEvent, at d: Date) {
        Task { _ = try? await store.splitEvent(id: e.id, at: d); await refresh() }
    }

    func merge(_ events: [ActivityEvent], as c: ActivityCategory) {
        Task {
            _ = try? await store.mergeEvents(ids: events.map(\.id),
                                             classification: Classification(category: c, confidence: 1, evidence: [.userCorrection],
                                                                            explanation: "Merged by you", origin: .userConfirmed))
            await refresh()
        }
    }

    func savePlan(_ p: PlanItem) { Task { try? await store.savePlanItem(p); await refresh() } }
    func deletePlan(_ p: PlanItem) { Task { try? await store.deletePlanItem(id: p.id); await refresh() } }
    func deleteRule(_ r: ClassificationRule) {
        Task {
            try? await store.deleteRule(id: r.id)
            await tracker.updateRules((try? await store.rules()) ?? [])
            await refresh()
        }
    }
    func addRule(_ r: ClassificationRule) {
        Task {
            try? await store.saveRule(r)
            await tracker.updateRules((try? await store.rules()) ?? [])
            await refresh()
        }
    }

    func exportData(to url: URL) {
        Task {
            do {
                let bundle = try await store.export()
                try AtlasJSON.string(bundle, iso: true, pretty: true).write(to: url, atomically: true, encoding: .utf8)
            } catch { lastError = "Export failed: \(error)" }
        }
    }

    func backup(to url: URL) {
        Task { do { try await store.backup(to: url) } catch { lastError = "Backup failed: \(error)" } }
    }

    func deleteAll(includeConfiguration: Bool) {
        Task {
            let wasRunning = await tracker.isRunning
            if wasRunning { await stopTracking() }
            do { try await store.deleteAllData(includeConfiguration: includeConfiguration) } catch { lastError = "\(error)" }
            if includeConfiguration { settings = AtlasSettings(); try? secrets.write(ClaudeProvider.apiKeyAccount, value: nil) }
            if wasRunning && settings.trackingEnabled { await startTracking() }
            await refresh()
        }
    }

    /// Posts a native notification the first time a new scheduled check-in is seen.
    private func announceNewCheckin() {
        guard !DemoData.isEnabled, let latest = checkins.first else { return }
        let key = "lastAnnouncedCheckin"
        let seen = UserDefaults.standard.string(forKey: key)
        guard seen != latest.id else { return }
        UserDefaults.standard.set(latest.id, forKey: key)
        // First launch only records the baseline; old check-ins never notify.
        guard seen != nil, Date().timeIntervalSince(latest.ts) < 2 * 3600,
              settings.notificationsEnabled, !NotificationService.isQuiet(settings.quietHours) else { return }
        let verdict = Verdict(latest.verdict)
        let parts = CheckinParts(latest.body)
        let body: String
        switch settings.notificationDetail {
        case .minimal: body = "New check-in: \(verdict.title)."
        case .summary: body = parts.next.map { "\(verdict.title). Next: \($0)" } ?? "\(verdict.title). \(parts.headline)"
        }
        NotificationService.post(id: "checkin-\(latest.id)", title: "ATLAS check-in", body: String(body.prefix(220)))
    }

    func setNotifyEmail(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespaces)
        notifyEmail = v
        Task { try? await store.setPreference(AtlasStore.notifyEmailKey, v.isEmpty ? nil : v) }
    }

    func payloadPreview(windowID: String) async -> String? { try? await coordinator.preview(windowID: windowID) }

    // MARK: - Derived

    var latestAnalyzed: (window: AnalysisWindow, analysis: ValidatedAnalysis)? {
        for w in windows where w.status == .analyzed {
            if let s = w.resultJSON, let v = try? AtlasJSON.decode(ValidatedAnalysis.self, from: s) { return (w, v) }
        }
        return nil
    }

    var todayTotals: [(ActivityCategory, TimeInterval, TimeInterval)] {
        let start = Calendar.current.startOfDay(for: Date())
        return TimeAccounting.totals(TimeAccounting.normalized(todayEvents, from: start, to: Date()))
            .map { ($0.key, $0.value.observed, $0.value.inferred) }
            .sorted { $0.1 > $1.1 }
    }

    var todayStateTotals: (active: TimeInterval, passive: TimeInterval, idle: TimeInterval, uncertain: TimeInterval) {
        let start = Calendar.current.startOfDay(for: Date())
        var r = (active: 0.0, passive: 0.0, idle: 0.0, uncertain: 0.0)
        for e in TimeAccounting.normalized(todayEvents, from: start, to: Date()) {
            switch e.state {
            case .active: r.active += e.duration
            case .passive: r.passive += e.duration
            case .idle, .away: r.idle += e.duration
            case .uncertain: r.uncertain += e.duration
            default: break
            }
            if e.state.isEngaged && e.classification.isUncertain { r.uncertain += e.duration }
        }
        return r
    }

    /// Whether the selected agent backend can run right now.
    var agentReady: Bool {
        settings.agentBackend == .claudeSubscription ? (claudeCodeAuth?.isSubscription ?? false) : hasAPIKey
    }

    var agentSetupHint: String {
        settings.agentBackend == .claudeSubscription
            ? "sign in to Claude Code with your Claude subscription (`claude auth login`)"
            : "add an Anthropic API key in Settings → Claude"
    }

    var awakeRemaining: TimeInterval {
        max(0, settings.analysisIntervalSeconds - (openWindow?.awakeSeconds ?? 0))
    }
}

struct PermissionStatus: Equatable {
    enum Grant: Equatable { case granted, denied, notDetermined }
    var accessibility = false
    var calendar: Grant = .notDetermined
    var chromeInstalled = false
    var chromeRunning = false
    var chromeAutomation: Grant = .notDetermined
    var chromeExtension = false
    var notifications = false
}
