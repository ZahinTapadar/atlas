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
    private var safari: SafariProbe!
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
    var lastError: String?
    var startupError: String?

    static func openStore() -> (AtlasStore, String?) {
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
        let provider = ClaudeProvider(secrets: KeychainStore())
        let ek = eventKit
        self.coordinator = AnalysisCoordinator(store: store, provider: provider, connectors: [ek],
                                               health: { await AppModel.healthNotesForAgent(ek) })
        self.workspace = WorkspaceMonitor { [weak self] o, d in self?.observe(o, at: d) }
        self.idle = IdleMonitor(threshold: settings.idleThresholdSeconds) { [weak self] o, d in self?.observe(o, at: d) }
        self.titles = WindowTitleObserver { [weak self] o, d in self?.observe(o, at: d) }
        self.safari = SafariProbe { [weak self] o, d in self?.observe(o, at: d) }
        Task { await self.boot() }
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
        if settings.trackingEnabled { await startTracking() }
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
        safari.enabled = settings.browserAutomationEnabled
        safari.frontmostChanged(to: front?.bundleID)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: TrackerCore.flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        tickTimer?.tolerance = 5
    }

    func stopTracking() async {
        workspace.stop()
        idle.stop()
        titles.follow(app: nil)
        safari.frontmostChanged(to: nil)
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
            safari.frontmostChanged(to: app.bundleID)
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
        if settings.agentEnabled {
            agentBusy = true
            await coordinator.processDueWindows()
            agentBusy = await coordinator.isProcessing
        }
        await refresh()
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
        } catch { lastError = "Could not read data: \(error)" }
        current = await tracker.currentSnapshot(at: now)
        calendarStatus = await eventKit.status()
        hasAPIKey = !(secrets.read(ClaudeProvider.apiKeyAccount) ?? "").isEmpty
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
        h.append(HealthItem(name: "Browser extension", level: !settings.browserExtensionEnabled ? .off : ext ? .ok : .degraded,
                            detail: ext ? "Reporting" : "Not detected — install from Settings → Browser"))
        h.append(HealthItem(name: "Safari", level: settings.browserAutomationEnabled ? .ok : .off,
                            detail: settings.browserAutomationEnabled ? "Automation enabled" : "Not tracked (enable in Settings → Browser)"))
        h.append(HealthItem(name: "Calendar", level: calendarStatus.isConnected ? .ok : .degraded, detail: calendarStatus.label))
        h.append(HealthItem(name: "Claude API", level: hasAPIKey ? .ok : .degraded,
                            detail: hasAPIKey ? "Key in Keychain" : "No API key — analyses will queue"))
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
            safari.enabled = s.browserAutomationEnabled
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

    var awakeRemaining: TimeInterval {
        max(0, settings.analysisIntervalSeconds - (openWindow?.awakeSeconds ?? 0))
    }
}
