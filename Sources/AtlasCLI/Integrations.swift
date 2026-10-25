import AtlasCore
import Foundation

/// Local integrations used by scheduled check-ins: Things 3 (via its scripting interface and URL scheme)
/// and Mail (to the one address configured in ATLAS settings). Arguments are passed to scripts as argv,
/// never interpolated into script source.
enum Integrations {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func osascript(js: String, args: [String] = []) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", js] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if e.contains("-1743") || e.lowercased().contains("not allowed") {
                throw Failure(message: "macOS denied automation access. Allow it in System Settings → Privacy & Security → Automation.")
            }
            throw Failure(message: e.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return o.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Things 3

    struct ThingsTodo: Codable {
        var id: String
        var title: String
        var status: String
        var notes: String
        var due: String?
        var tags: [String]
        var project: String?
    }

    /// To-dos in Things' Today list (including overdue items Things shows there).
    static func thingsToday() throws -> [ThingsTodo] {
        let js = """
        function run(argv) {
          const T = Application('Things3');
          const iso = d => { try { return d ? d.toISOString().slice(0, 10) : null } catch (e) { return null } };
          return JSON.stringify(T.lists.byName('Today').toDos().map(t => {
            let project = null; try { const p = t.project(); project = p ? p.name() : null } catch (e) {}
            return { id: t.id(), title: t.name(), status: t.status(), notes: (t.notes() || '').slice(0, 400),
                     due: iso(t.dueDate()), tags: (t.tagNames() || '').split(', ').filter(x => x), project: project };
          }));
        }
        """
        let raw = try osascript(js: js)
        return try JSONDecoder().decode([ThingsTodo].self, from: Data(raw.utf8))
    }

    enum ThingsAction: String { case complete, reopen, appendNote = "append_note" }

    static func updateThings(id: String, action: ThingsAction, note: String?) throws {
        let js = """
        function run(argv) {
          const T = Application('Things3');
          const t = T.toDos.byId(argv[0]);
          t.name();  // throws if the id does not exist
          if (argv[1] === 'complete') t.status = 'completed';
          else if (argv[1] === 'reopen') t.status = 'open';
          if (argv[2]) t.notes = (t.notes() ? t.notes() + '\\n\\n' : '') + argv[2];
          return 'ok';
        }
        """
        let stamp = note.map { "ATLAS · \(Self.stamp()): \($0)" } ?? ""
        try osascript(js: js, args: [id, action == .appendNote ? "note" : action.rawValue, stamp])
    }

    /// Adds a to-do to Things' Today list via the documented URL scheme (no auth token needed for add).
    static func addThings(title: String, notes: String?, when: String) throws {
        var c = URLComponents(string: "things:///add")!
        c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "when", value: when),
                        URLQueryItem(name: "notes", value: "Added by ATLAS · \(stamp())" + (notes.map { "\n\n\($0)" } ?? "")),
                        URLQueryItem(name: "reveal", value: "false")]
        guard let url = c.url else { throw Failure(message: "Bad to-do") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", url.absoluteString]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(message: "Things did not accept the to-do") }
    }

    // MARK: Mail

    /// Sends a plain-text email from the default Mail account to `to`.
    static func sendEmail(to: String, subject: String, body: String) throws {
        let js = """
        function run(argv) {
          const Mail = Application('Mail');
          const m = Mail.OutgoingMessage({ subject: argv[1], content: argv[2], visible: false });
          Mail.outgoingMessages.push(m);
          m.toRecipients.push(Mail.Recipient({ address: argv[0] }));
          m.send();
          return 'sent';
        }
        """
        try osascript(js: js, args: [to, subject, body])
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: Date())
    }

    static func isPlausibleEmail(_ s: String) -> Bool {
        s.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
}
