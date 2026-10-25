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

    /// Things' Today list with project contents, checklists and any reason the user recorded in ATLAS today.
    static func thingsToday() async throws -> [Things.Item] {
        var items = try Things.today()
        if let store = try? AtlasStore(path: AtlasStore.defaultPath, readOnly: true),
           let reasons = try? await store.todoReasons(since: AtlasStore.dayKey()) {
            for i in items.indices { items[i].reason = reasons.first { $0.key == items[i].id || $0.title == items[i].title }?.reason }
        }
        return items
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

    /// Sends a plain-text email to `to`. When Mail has an account for the recipient's own address, the message
    /// is sent from it: mail to yourself through your provider's SMTP is not filtered as spam, whereas a
    /// message from another of your accounts (e.g. iCloud to Gmail) often is.
    static func sendEmail(to: String, subject: String, body: String) throws {
        let js = """
        function run(argv) {
          const Mail = Application('Mail');
          const to = argv[0].toLowerCase();
          const own = Mail.accounts().find(a => { try { return a.enabled() && a.emailAddresses().some(e => e.toLowerCase() === to) } catch (e) { return false } });
          const props = { subject: argv[1], content: argv[2], visible: false };
          if (own) props.sender = argv[0];
          const m = Mail.OutgoingMessage(props);
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
