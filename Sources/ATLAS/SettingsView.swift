import AtlasCore
import AtlasPlatform
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "globe") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }
            CalendarSettings().tabItem { Label("Calendar", systemImage: "calendar") }
            RulesSettings().tabItem { Label("Rules", systemImage: "list.bullet.indent") }
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .scenePadding()
    }
}

/// Binding into a settings key path that persists on change.
@MainActor
func setting<T>(_ model: AppModel, _ kp: WritableKeyPath<AtlasSettings, T>) -> Binding<T> {
    Binding(get: { model.settings[keyPath: kp] }, set: { v in model.update { $0[keyPath: kp] = v } })
}

struct MinutePicker: View {
    var label: String
    @Binding var minutes: Int
    var body: some View {
        DatePicker(label, selection: Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes * 60)) },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0) }),
                   displayedComponents: .hourAndMinute)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("Tracking") {
                Toggle("Tracking enabled", isOn: setting(model, \.trackingEnabled))
                Toggle("Private mode (record only active/idle time, no apps, titles or sites)", isOn: setting(model, \.privateMode))
                Toggle("Launch at login", isOn: setting(model, \.launchAtLogin))
                Toggle("Capture window titles (needs Accessibility)", isOn: setting(model, \.captureWindowTitles))
                if !AXIsProcessTrusted() {
                    HStack {
                        Text("Accessibility not granted. ATLAS still tracks apps; titles improve classification.").font(.caption)
                        Button("Grant…") { WindowTitleObserver.requestTrust() }
                    }
                }
            }
            Section("Activity detection") {
                Stepper("Idle after \(Int(model.settings.idleThresholdSeconds / 60)) min without input",
                        value: setting(model, \.idleThresholdSeconds), in: 60...1800, step: 60)
                Stepper("Reading/watching counts as engaged for \(Int(model.settings.passiveGraceSeconds / 60)) min without input",
                        value: setting(model, \.passiveGraceSeconds), in: 120...3600, step: 60)
                Stepper("Away after \(Int(model.settings.awayThresholdSeconds / 60)) min idle (never treated as sleep)",
                        value: setting(model, \.awayThresholdSeconds), in: 300...7200, step: 300)
            }
            Section("Analysis windows") {
                Picker("Analyze every", selection: setting(model, \.analysisIntervalHours)) {
                    Text("2 hours").tag(2.0); Text("3 hours").tag(3.0); Text("4 hours").tag(4.0); Text("6 hours").tag(6.0)
                }
                Text("Measured in awake time: sleep, lock and long absences don't count.").font(.caption).foregroundStyle(.secondary)
                Stepper("A sleep/absence of \(Int(model.settings.dayBreakSleepHours)) h ends the day",
                        value: setting(model, \.dayBreakSleepHours), in: 2...12)
                MinutePicker(label: "Usual sleep", minutes: Binding(get: { model.settings.sleepSchedule.startMinute },
                                                                     set: { v in model.update { $0.sleepSchedule.startMinute = v } }))
                MinutePicker(label: "Usual wake", minutes: Binding(get: { model.settings.sleepSchedule.endMinute },
                                                                    set: { v in model.update { $0.sleepSchedule.endMinute = v } }))
                MinutePicker(label: "Working hours start", minutes: Binding(get: { model.settings.workingHours.startMinute },
                                                                             set: { v in model.update { $0.workingHours.startMinute = v } }))
                MinutePicker(label: "Working hours end", minutes: Binding(get: { model.settings.workingHours.endMinute },
                                                                           set: { v in model.update { $0.workingHours.endMinute = v } }))
            }
            Section("Notifications") {
                Toggle("Notify when a report is ready", isOn: setting(model, \.notificationsEnabled))
                Picker("Detail", selection: setting(model, \.notificationDetail)) {
                    Text("Minimal (lock-screen safe)").tag(NotificationDetail.minimal)
                    Text("Summary (categories and top task, no sites)").tag(NotificationDetail.summary)
                }
                Toggle("Quiet hours", isOn: Binding(get: { model.settings.quietHours != nil },
                                                    set: { v in model.update { $0.quietHours = v ? DailyHours(startMinute: 1320, endMinute: 480) : nil } }))
                if let q = model.settings.quietHours {
                    MinutePicker(label: "From", minutes: Binding(get: { q.startMinute }, set: { v in model.update { $0.quietHours?.startMinute = v } }))
                    MinutePicker(label: "Until", minutes: Binding(get: { q.endMinute }, set: { v in model.update { $0.quietHours?.endMinute = v } }))
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ListEditor: View {
    var title: String
    var placeholder: String
    @Binding var items: [String]
    @State private var draft = ""
    var body: some View {
        Section(title) {
            ForEach(items, id: \.self) { i in
                HStack { Text(i).font(.callout.monospaced()); Spacer(); Button { items.removeAll { $0 == i } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) }
            }
            HStack {
                TextField(placeholder, text: $draft).onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
    private func add() {
        let v = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !v.isEmpty, !items.contains(v) else { return }
        items.append(v)
        draft = ""
    }
}

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var deleteConfig = false

    var body: some View {
        Form {
            Section {
                Text("Everything is stored locally in \(AtlasStore.defaultDirectory.path). ATLAS never records keystrokes, screenshots, screen contents, form fields, passwords, document contents, source code or terminal commands.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ListEditor(title: "Excluded apps (bundle IDs) — nothing identifying is recorded", placeholder: "com.example.app",
                       items: setting(model, \.excludedBundleIDs))
            ListEditor(title: "Excluded sites — nothing identifying is recorded", placeholder: "example.com",
                       items: setting(model, \.excludedDomains))
            ListEditor(title: "Sensitive apps — kept locally, never sent to Claude by name", placeholder: "com.example.app",
                       items: setting(model, \.sensitiveBundleIDs))
            ListEditor(title: "Sensitive sites (domain or keyword)", placeholder: "bank",
                       items: setting(model, \.sensitiveDomains))
            Section("Retention") {
                Stepper("Keep activity for \(model.settings.retentionDays) days", value: setting(model, \.retentionDays), in: 7...730, step: 7)
                Stepper("Keep request logs for \(model.settings.requestLogRetentionDays) days", value: setting(model, \.requestLogRetentionDays), in: 1...365)
            }
            Section("Your data") {
                HStack {
                    Button("Export JSON…") { save("atlas-export.json", .json) { model.exportData(to: $0) } }
                    Button("Back up database…") { save("atlas-backup.sqlite", .data) { model.backup(to: $0) } }
                }
                Toggle("Also delete settings, rules and API key", isOn: $deleteConfig)
                Button("Delete all activity data…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all ATLAS data?", isPresented: $confirmDelete) {
            Button("Delete permanently", role: .destructive) { model.deleteAll(includeConfiguration: deleteConfig) }
        } message: {
            Text("Activity, sessions, analyses, plan items and action history are removed from this Mac. Calendar events ATLAS created stay on your calendar.")
        }
    }

    private func save(_ name: String, _ type: UTType, _ done: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        if panel.runModal() == .OK, let url = panel.url { done(url) }
    }
}

struct BrowserSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("Chrome, Edge, Brave, Arc, Vivaldi (extension)") {
                Toggle("Use browser extension data", isOn: setting(model, \.browserExtensionEnabled))
                Text("""
                macOS can't see browser tabs on its own. The ATLAS extension reports the active tab's domain and title \
                through Chrome native messaging (no local server). To install:
                1. Run scripts/install-native-host.sh (registers the atlas-nm-host helper).
                2. Open chrome://extensions, enable Developer mode, "Load unpacked" → Extensions/chromium.
                3. Copy the extension ID into the script if prompted.
                """).font(.caption).textSelection(.enabled)
                Toggle("Record incognito/private tabs (also needs \"Allow in Incognito\")", isOn: setting(model, \.trackIncognito))
                Toggle("Store full URLs (otherwise domain + title only)", isOn: setting(model, \.captureFullURLs))
            }
            Section("Firefox") {
                Text("Load Extensions/firefox via about:debugging → This Firefox → Load Temporary Add-on, then run scripts/install-native-host.sh --firefox.")
                    .font(.caption)
            }
            Section("Safari") {
                Toggle("Ask Safari for its front tab via Automation", isOn: setting(model, \.browserAutomationEnabled))
                Text("Safari extensions must ship in a signed Xcode app, so ATLAS uses Apple Events instead: only while Safari is frontmost, every 15 s. macOS asks for permission the first time. Private windows aren't reported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ClaudeSettings: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""

    static let prices: [String: (Double, Double)] = [
        "claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10), "claude-haiku-5-5": (0.10, 0.50), "claude-fable-5-1": (10, 50),
    ]

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Run analyses with", selection: setting(model, \.agentBackend)) {
                    ForEach(AgentBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                switch model.settings.agentBackend {
                case .claudeSubscription:
                    LabeledContent("Claude Code CLI", value: model.claudeCodePath ?? "Not found")
                    LabeledContent("Sign-in", value: model.claudeCodeAuth.map {
                        $0.isSubscription ? "Claude subscription ✓" : $0.loggedIn ? "\($0.method) — not a subscription" : "Not signed in"
                    } ?? "Unknown")
                    TextField("Custom CLI path (optional)", text: Binding(
                        get: { model.settings.claudeExecutablePath ?? "" },
                        set: { v in model.update { $0.claudeExecutablePath = v.isEmpty ? nil : v } }))
                    HStack {
                        Button("Check again") { Task { await model.refresh() } }
                        Button("Copy sign-in command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("claude auth login", forType: .string)
                        }
                    }
                    Text("Uses your Claude plan's usage limits, not API credits. ATLAS strips API-key variables before launching Claude Code and refuses to run unless it is signed in with a Claude subscription, so it never bills an API key by accident. Each analysis is one tool-less `claude -p` call from an empty folder.")
                        .font(.caption).foregroundStyle(.secondary)
                case .anthropicAPI:
                    HStack {
                        SecureField(model.hasAPIKey ? "Key stored in Keychain — enter to replace" : "Anthropic API key", text: $key)
                        Button("Save") { model.setAPIKey(key); key = "" }.disabled(key.isEmpty)
                        if model.hasAPIKey { Button("Remove", role: .destructive) { model.setAPIKey("") } }
                    }
                    Text("Billed per token to your Anthropic Console account.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Agent enabled", isOn: setting(model, \.agentEnabled))
                Picker("Model", selection: setting(model, \.model)) {
                    Text("Claude Opus 5.5").tag("claude-opus-5-5")
                    Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                    Text("Claude Haiku 5.5").tag("claude-haiku-5-5")
                }
                Picker("Effort", selection: setting(model, \.effort)) {
                    ForEach(["low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            Section("What gets sent") {
                Toggle("Review each request before sending", isOn: setting(model, \.reviewBeforeSending))
                Toggle("Include window/page titles (non-sensitive only)", isOn: setting(model, \.sendWindowTitles))
                Stepper("Max timeline rows: \(model.settings.maxTimelineEntries)", value: setting(model, \.maxTimelineEntries), in: 20...400, step: 20)
                Stepper("Max request size: \(model.settings.maxRequestBytes / 1000) KB", value: setting(model, \.maxRequestBytes), in: 10_000...200_000, step: 10_000)
                Text("Only a per-window summary is sent — never a live stream, full browsing history, full URLs, or document contents. Use Agent → \"What was sent\" to inspect any request.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Retries") {
                Stepper("Max attempts per window: \(model.settings.maxRetries)", value: setting(model, \.maxRetries), in: 1...20)
                Stepper("First retry after \(Int(model.settings.retryBaseSeconds)) s (doubles each time)", value: setting(model, \.retryBaseSeconds), in: 15...1800, step: 15)
            }
            Section("Rubric weights (normalized automatically)") {
                weight("Priority alignment", \.rubricWeights.priorityAlignment)
                weight("Planned task completion", \.rubricWeights.taskCompletion)
                weight("Focus & continuity", \.rubricWeights.focusContinuity)
                weight("Schedule adherence", \.rubricWeights.scheduleAdherence)
            }
            Section("Usage") {
                let log = model.requestLog
                let input = log.compactMap(\.inputTokens).reduce(0, +), output = log.compactMap(\.outputTokens).reduce(0, +)
                let price = Self.prices[model.settings.model] ?? (4, 20)
                if model.settings.agentBackend == .claudeSubscription {
                    Text("\(log.count) requests · \(input) input / \(output) output tokens · counted against your Claude plan's usage limits")
                        .font(.callout)
                } else {
                    Text("\(log.count) requests · \(input) input / \(output) output tokens · ≈ $\(String(format: "%.2f", Double(input) / 1e6 * price.0 + Double(output) / 1e6 * price.1)) at \(model.settings.model) list prices")
                        .font(.callout)
                }
                ForEach(log.prefix(8)) { e in
                    Text("\(Fmt.dayTime.string(from: e.ts)) · \(e.model) · \(e.requestBytes / 1000) KB · \(e.outcome)").font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
    }

    private func weight(_ label: String, _ kp: WritableKeyPath<AtlasSettings, Double>) -> some View {
        HStack {
            Text(label).frame(width: 190, alignment: .leading)
            Slider(value: setting(model, kp), in: 0...1, step: 0.05)
            Text("\(Int(model.settings[keyPath: kp] / max(model.settings.rubricWeights.total, 0.0001) * 100))%").monospacedDigit().frame(width: 40)
        }
    }
}

struct CalendarSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section("Apple Calendar & Reminders") {
                HStack {
                    Text(model.calendarStatus.label)
                    Spacer()
                    if !model.calendarStatus.isConnected { Button("Connect…") { model.requestCalendarAccess() } }
                }
                Picker("Calendar for new blocks", selection: setting(model, \.targetCalendarID)) {
                    Text("Default calendar").tag(String?.none)
                    ForEach(model.eventKit.writableCalendars(), id: \.id) { Text($0.title).tag(String?.some($0.id)) }
                }
            }
            Section("Authorization") {
                Picker("Agent may", selection: setting(model, \.authorizationLevel)) {
                    Text("Level 1 — read only").tag(AuthorizationLevel.readOnly)
                    Text("Level 2 — propose; I approve each change").tag(AuthorizationLevel.approvalRequired)
                    Text("Level 3 — bounded automation").tag(AuthorizationLevel.boundedAutomation)
                }
                .pickerStyle(.radioGroup)
                if model.settings.authorizationLevel == .boundedAutomation {
                    ForEach([AgentActionKind.createFocusBlock, .createBreak, .rescheduleTask, .createReminder], id: \.self) { k in
                        Toggle("Automatically: \(k.rawValue.replacingOccurrences(of: "_", with: " "))", isOn: Binding(
                            get: { model.settings.boundedRules.autoKinds.contains(k) },
                            set: { v in model.update { if v { $0.boundedRules.autoKinds.insert(k) } else { $0.boundedRules.autoKinds.remove(k) } } }))
                    }
                    Stepper("Only within the next \(Int(model.settings.boundedRules.horizonHours)) hours",
                            value: setting(model, \.boundedRules.horizonHours), in: 1...48)
                    Toggle("Only inside working hours", isOn: setting(model, \.boundedRules.requireWorkingHours))
                }
                Text("Never, at any level: moving or editing events with other attendees or not created by ATLAS, sending invitations, cancelling appointments, or deleting tasks. Every change is logged with a before/after diff and can be undone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scheduling") {
                Stepper("Buffer around meetings: \(model.settings.bufferMinutes) min", value: setting(model, \.bufferMinutes), in: 0...60, step: 5)
                Stepper("Suggest a break every \(model.settings.breakEveryMinutes) min", value: setting(model, \.breakEveryMinutes), in: 30...240, step: 15)
            }
        }
        .formStyle(.grouped)
    }
}

struct RulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var field: RuleField = .domain
    @State private var pattern = ""
    @State private var title = ""
    @State private var category: ActivityCategory = .research

    var body: some View {
        Form {
            Section("Add rule") {
                Picker("Match", selection: $field) {
                    Text("Site domain").tag(RuleField.domain); Text("App bundle ID").tag(RuleField.bundleID)
                    Text("App name").tag(RuleField.appName); Text("Title contains").tag(RuleField.titleContains)
                }
                TextField("Pattern", text: $pattern)
                TextField("…and title contains (optional)", text: $title)
                Picker("Category", selection: $category) { ForEach(ActivityCategory.allCases) { Text($0.displayName).tag($0) } }
                Button("Add Rule") {
                    model.addRule(ClassificationRule(field: field, pattern: pattern, titleContains: title.isEmpty ? nil : title,
                                                     category: category, confidence: 0.9, source: .user))
                    pattern = ""; title = ""
                }
                .disabled(pattern.isEmpty)
            }
            Section("Your rules and corrections (applied before built-in rules)") {
                if model.rules.isEmpty { Text("None yet. Recategorize items in the Timeline to teach ATLAS.").foregroundStyle(.secondary) }
                ForEach(model.rules) { r in
                    HStack {
                        Image(systemName: r.source == .correction ? "checkmark.seal" : "line.3.horizontal.decrease")
                        Text("\(r.field.rawValue): \(r.pattern)\(r.titleContains.map { " + “\($0)”" } ?? "")").font(.callout.monospaced())
                        Spacer()
                        Text(r.category.displayName).foregroundStyle(r.category.color)
                        Button { model.deleteRule(r) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DiagnosticsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var schema = 0
    @State private var integrity = true

    var body: some View {
        Form {
            Section("Tracking health") {
                ForEach(model.health) { h in
                    HStack { StatusDot(level: h.level); Text(h.name); Spacer(); Text(h.detail).foregroundStyle(.secondary).font(.caption) }
                }
            }
            Section("Storage") {
                LabeledContent("Database", value: model.store.path)
                LabeledContent("Schema version", value: "\(schema)")
                LabeledContent("Integrity", value: integrity ? "OK" : "Problem detected — export and back up")
                LabeledContent("Browser inbox", value: BrowserInbox.defaultDirectory.path)
            }
            Section("Permissions ATLAS uses") {
                Text("""
                • Accessibility (optional): reads the focused window's title. Without it, ATLAS tracks apps only.
                • Calendars & Reminders (optional): reads events to avoid conflicts; writes only per your authorization level.
                • Automation → Safari (optional): reads Safari's front tab URL and title.
                • Notifications (optional): report-ready alerts.
                No Screen Recording, Input Monitoring or Full Disk Access is requested.
                """).font(.caption)
            }
        }
        .formStyle(.grouped)
        .task {
            schema = await model.store.schemaVersion
            integrity = await model.store.integrityOK()
        }
    }
}
