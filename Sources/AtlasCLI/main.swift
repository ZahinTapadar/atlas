import AtlasCore
import Foundation

// atlasctl — read ATLAS's tracked activity from the terminal or as an MCP server.
//
//   atlasctl today [--json] [--timeline]        today's summary
//   atlasctl summary --from X --to Y [--json]   X/Y: ISO-8601, today, yesterday, now, -3h, last_90m
//   atlasctl now                                current activity
//   atlasctl checkins [--limit N]               recent check-in feedback
//   atlasctl checkin --verdict V [--source S]   record feedback (body on stdin)
//   atlasctl mcp                                MCP server over stdio
//
// Reads go through a read-only SQLite connection; only `checkin` writes, to its own table.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("atlasctl: \(msg)\n".utf8))
    exit(1)
}

func arg(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func readStore() throws -> AtlasStore {
    guard FileManager.default.fileExists(atPath: AtlasStore.defaultPath) else {
        throw NSError(domain: "atlasctl", code: 1, userInfo: [NSLocalizedDescriptionKey: "No ATLAS database yet. Open ATLAS.app to start tracking."])
    }
    return try AtlasStore(path: AtlasStore.defaultPath, readOnly: true)
}

func health(_ store: AtlasStore) async -> [String] {
    var notes: [String] = []
    let s = (try? await store.loadSettings()) ?? AtlasSettings()
    if !s.trackingEnabled { notes.append("Tracking is paused in ATLAS") }
    if s.privateMode { notes.append("Private mode: apps and sites are not recorded") }
    if let seen = BrowserInbox.lastActivity(), Date().timeIntervalSince(seen) < 6 * 3600 {} else if !s.browserAutomationEnabled {
        notes.append("No browser tab data: browser time is unclassified")
    }
    return notes
}

func digest(from: String?, to: String?, timeline: Bool) async throws -> ActivityDigest {
    let store = try readStore()
    let now = Date()
    guard let (f, t) = DigestRange.parse(from: from, to: to, now: now) else {
        throw NSError(domain: "atlasctl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid range"])
    }
    let settings = (try? await store.loadSettings()) ?? AtlasSettings()
    let events = try await store.events(from: f, to: t)
    return ActivityDigest.build(events: events, from: f, to: t, now: now, includeTimeline: timeline,
                                sendTitles: settings.sendWindowTitles, trackingHealth: await health(store))
}

func json<T: Encodable>(_ v: T) -> String { (try? AtlasJSON.string(v, iso: true, pretty: true)) ?? "{}" }

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "today"

switch command {
case "today", "summary":
    do {
        let d = try await digest(from: command == "today" ? "today" : arg("--from", args), to: arg("--to", args),
                                 timeline: args.contains("--timeline"))
        print(args.contains("--json") ? json(d) : d.markdown)
    } catch { fail(error.localizedDescription) }

case "now":
    do {
        let d = try await digest(from: "-10m", to: "now", timeline: false)
        if let c = d.current { print("\(c.source) — \(c.category) (\(c.state)), \(Int(c.minutes)) min") }
        else { print(d.trackerRunning ? "No current activity" : "Tracker not running") }
    } catch { fail(error.localizedDescription) }

case "checkins":
    do {
        let list = try await readStore().checkins(limit: Int(arg("--limit", args) ?? "10") ?? 10)
        print(json(list))
    } catch { fail(error.localizedDescription) }

case "checkin":
    let body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { fail("pipe the feedback text on stdin") }
    do {
        let store = try AtlasStore(path: AtlasStore.defaultPath)
        try await store.saveCheckin(.init(source: arg("--source", args) ?? "cli", verdict: arg("--verdict", args), body: body))
        print("saved")
    } catch { fail(error.localizedDescription) }

case "set-email":
    guard let addr = args.dropFirst().first, Integrations.isPlausibleEmail(addr) else { fail("usage: atlasctl set-email you@example.com") }
    do {
        try await AtlasStore(path: AtlasStore.defaultPath).setPreference(AtlasStore.notifyEmailKey, addr)
        print("Check-in emails will go to \(addr)")
    } catch { fail(error.localizedDescription) }

case "things":
    do {
        for t in try await Integrations.thingsToday() { print("[\(t.status)] \(t.title)  (\(t.id))") }
    } catch { fail(error.localizedDescription) }

case "test-email":
    do {
        let latest = try await readStore().checkins(limit: 1).first
        print(try await CheckinMail.deliver(subject: "ATLAS · test · \(latest.map { RichEmail.verdictTitle($0.verdict) } ?? "check-in")",
                                            body: latest?.body ?? "Check-in emails from ATLAS will arrive like this."))
    } catch { fail(error.localizedDescription) }

case "preview-email":
    // Writes the designed email and its GIF to a folder, for a look in a browser.
    do {
        let dir = URL(fileURLWithPath: args.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let store = try readStore()
        let latest = try await store.checkins(limit: 1).first
        let c = RichEmail.build(checkin: latest, fallbackSubject: "ATLAS preview", fallbackBody: latest?.body ?? "",
                                events: try await store.events(from: Calendar.current.startOfDay(for: Date()), to: Date()),
                                reasons: (try? await store.todoReasons(since: AtlasStore.dayKey())) ?? [])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try c.html.replacingOccurrences(of: "cid:day@atlas", with: "day.gif").write(to: dir.appendingPathComponent("email.html"), atomically: true, encoding: .utf8)
        if let gif = c.gif { try gif.write(to: dir.appendingPathComponent("day.gif")) }
        print(dir.appendingPathComponent("email.html").path)
    } catch { fail(error.localizedDescription) }

case "email-setup":
    // Stores an app password for the check-in address in the login Keychain, then sends a designed test email.
    do {
        guard let to = try await readStore().preference(AtlasStore.notifyEmailKey) else { fail("run atlasctl set-email first") }
        guard SMTPMail.server(for: to) != nil else { fail("HTML email currently supports Gmail and iCloud addresses; \(to) will keep getting plain text.") }
        print("""
        ATLAS sends designed check-in emails through your own mail server, signed in with an app password.
        \(to.hasSuffix("gmail.com") || to.hasSuffix("googlemail.com")
            ? "Create one at https://myaccount.google.com/apppasswords (needs 2-Step Verification), name it ATLAS."
            : "Create one at https://account.apple.com → Sign-In and Security → App-Specific Passwords.")
        It is checked by sending you a test email, then kept in your login Keychain as "ATLAS SMTP".
        Nothing you type is shown or saved anywhere else.

        """)
        guard let entered = SMTPMail.readSecret(prompt: "App password (hidden): ") else { fail("No password entered.") }
        let pass = entered.replacingOccurrences(of: " ", with: "")
        guard pass.range(of: #"^[A-Za-z0-9-]{12,40}$"#, options: .regularExpression) != nil else {
            fail("That doesn't look like an app password (16 letters for Gmail). Nothing was saved.")
        }
        let store = try readStore()
        let latest = try await store.checkins(limit: 1).first
        print("Sending a test email…")
        let content = try await CheckinMail.content(store: store, subject: "ATLAS · your check-ins now look like this",
                                                   body: latest?.body ?? "ATLAS is set up.")
        try SMTPMail.send(to: to, content: content, password: pass)
        try SMTPMail.savePassword(pass, for: to)
        print("Sent to \(to), and saved. Scheduled check-ins will now arrive as designed emails.")
    } catch { fail(error.localizedDescription) }

case "mcp":
    await MCPServer().run()

case "-h", "--help", "help":
    print("""
    atlasctl today [--json] [--timeline]
    atlasctl summary --from <when> --to <when> [--json] [--timeline]   when: ISO-8601 | today | yesterday | now | -3h | last_90m
    atlasctl now
    atlasctl checkins [--limit N]
    atlasctl checkin --verdict on_track|mixed|off_track|insufficient_data [--source NAME] < feedback.txt
    atlasctl things                        today's Things to-dos
    atlasctl set-email you@example.com     where check-in emails go
    atlasctl test-email                    send the latest check-in as an email
    atlasctl email-setup                   store an app password for designed HTML check-in emails
    atlasctl preview-email [dir]           write the designed email to a folder
    atlasctl mcp
    """)

default:
    fail("unknown command \(command); try --help")
}
