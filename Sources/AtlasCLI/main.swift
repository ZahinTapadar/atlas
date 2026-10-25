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
        for t in try Integrations.thingsToday() { print("[\(t.status)] \(t.title)  (\(t.id))") }
    } catch { fail(error.localizedDescription) }

case "test-email":
    do {
        guard let to = try await readStore().preference(AtlasStore.notifyEmailKey) else { fail("run atlasctl set-email first") }
        try Integrations.sendEmail(to: to, subject: "ATLAS test email", body: "Check-in emails from ATLAS will arrive like this.")
        print("Sent to \(to)")
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
    atlasctl test-email
    atlasctl mcp
    """)

default:
    fail("unknown command \(command); try --help")
}
