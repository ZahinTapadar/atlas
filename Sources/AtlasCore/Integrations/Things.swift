import Foundation

/// Read access to Things 3, shared by the app and `atlasctl`.
///
/// The Today list, project contents and status changes go through Things' scripting interface. Checklist
/// items are not scriptable, so they are read (read-only) from Things' own database; macOS asks the user
/// once before allowing that, and the list simply has no checklists until it is allowed.
public enum Things {
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        /// "open" | "completed" | "canceled"
        public var status: String
        public var notes: String
        public var due: String?
        public var project: String?
        public var isProject: Bool
        /// To-dos inside a project.
        public var children: [Child]
        /// Checklist items inside a to-do (nil when Things' database could not be read).
        public var checklist: [Child]?
        /// The user's own reason for not doing it today, stored in ATLAS.
        public var reason: String?

        public init(id: String, title: String, status: String = "open", notes: String = "", due: String? = nil, project: String? = nil,
                    isProject: Bool = false, children: [Child] = [], checklist: [Child]? = nil, reason: String? = nil) {
            self.id = id; self.title = title; self.status = status; self.notes = notes; self.due = due; self.project = project
            self.isProject = isProject; self.children = children; self.checklist = checklist; self.reason = reason
        }

        public var isDone: Bool { status == "completed" }
    }

    public struct Child: Codable, Sendable, Hashable {
        public var id: String?
        public var title: String
        public var done: Bool
        public init(id: String? = nil, title: String, done: Bool) { self.id = id; self.title = title; self.done = done }
    }

    public struct Failure: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Things' Today list (including overdue items it shows there), with project contents and checklists.
    public static func today() throws -> [Item] {
        let js = """
        function run(argv) {
          const T = Application('Things3');
          const iso = d => { try { return d ? d.toISOString().slice(0, 10) : null } catch (e) { return null } };
          const projectIDs = new Set(T.projects.id());
          return JSON.stringify(T.lists.byName('Today').toDos().map(t => {
            const id = t.id();
            let project = null; try { const p = t.project(); project = p ? p.name() : null } catch (e) {}
            let notes = ''; try { notes = (t.notes() || '').slice(0, 2000) } catch (e) {}
            let due = null; try { due = iso(t.dueDate()) } catch (e) {}
            const isProject = projectIDs.has(id);
            let children = [];
            if (isProject) {
              try { children = T.projects.byId(id).toDos().map(c => ({ id: c.id(), title: c.name(), done: c.status() === 'completed' })) } catch (e) {}
            }
            return { id: id, title: t.name(), status: t.status(), notes: notes, due: due, project: project, isProject: isProject, children: children };
          }));
        }
        """
        var items = try JSONDecoder().decode([Item].self, from: Data(try osascript(js: js).utf8))
        if let lists = checklists(for: items.filter { !$0.isProject }.map(\.id)) {
            for i in items.indices where !items[i].isProject { items[i].checklist = lists[items[i].id] ?? [] }
        }
        return items
    }

    /// Marks a to-do (or project to-do) done or open again.
    public static func setDone(id: String, _ done: Bool) throws {
        let js = """
        function run(argv) {
          const t = Application('Things3').toDos.byId(argv[0]);
          t.name();
          t.status = argv[1] === 'done' ? 'completed' : 'open';
          return 'ok';
        }
        """
        try osascript(js: js, args: [id, done ? "done" : "open"])
    }

    /// Opens an item in Things.
    public static func reveal(id: String) {
        guard let url = URL(string: "things:///show?id=\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [url.absoluteString]
        try? p.run()
    }

    // MARK: Checklists (Things database, read-only)

    /// Where Things keeps its database, if this process may see it.
    public static var databasePath: String? {
        let group = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: group.path) else { return nil }
        for dir in entries.sorted() where dir.hasPrefix("ThingsData") {
            let path = group.appendingPathComponent(dir).appendingPathComponent("Things Database.thingsdatabase/main.sqlite").path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        let legacy = group.appendingPathComponent("Things Database.thingsdatabase/main.sqlite").path
        return FileManager.default.fileExists(atPath: legacy) ? legacy : nil
    }

    /// Checklist items keyed by to-do id, or nil when the database is not readable.
    public static func checklists(for ids: [String]) -> [String: [Child]]? {
        guard !ids.isEmpty else { return [:] }
        guard let path = databasePath, let db = try? SQLiteConnection(path: path, readOnly: true) else { return nil }
        let ph = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try? db.query("""
            SELECT uuid, title, status, task FROM TMChecklistItem
            WHERE task IN (\(ph)) ORDER BY task, "index"
            """, ids.map { $0 as SQLBindable }) { r in
            (r.string("task") ?? "", Child(id: r.string("uuid"), title: r.string("title") ?? "", done: (r.int("status") ?? 0) != 0))
        }
        guard let rows else { return nil }
        return Dictionary(grouping: rows, by: \.0).mapValues { $0.map(\.1) }
    }

    // MARK: Scripting

    @discardableResult
    public static func osascript(js: String, args: [String] = []) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", js] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: e, as: UTF8.self)
            if msg.contains("-1743") || msg.lowercased().contains("not allowed") {
                throw Failure(message: "macOS denied automation access. Allow it in System Settings → Privacy & Security → Automation.")
            }
            if msg.contains("-600") || msg.contains("-1728") { throw Failure(message: "Things 3 is not installed or not running.") }
            throw Failure(message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
