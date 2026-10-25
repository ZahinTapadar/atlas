import Foundation

/// File-based handoff between the browser native-messaging host and the app.
///
/// The host (launched by the browser, not by ATLAS) appends one JSON message per line to
/// `<inbox>/<pid>.jsonl`. The app drains completed files on its normal tick. No local server, no socket.
/// Malformed lines are skipped: a misbehaving extension can never crash the tracker.
public struct BrowserMessage: Codable, Sendable, Hashable {
    public var v: Int
    /// "tab" (active tab changed/updated), "focus" (browser window focus), "hello", "bye"
    public var type: String
    public var ts: Double
    public var family: String
    public var url: String?
    public var title: String?
    public var incognito: Bool?
    public var audible: Bool?
    public var focused: Bool?
}

public enum BrowserInbox {
    public static var defaultDirectory: URL { AtlasStore.defaultDirectory.appendingPathComponent("BrowserInbox", isDirectory: true) }

    public static func parse(line: String) -> BrowserMessage? {
        guard line.count < 16_384, let data = line.data(using: .utf8),
              let m = try? JSONDecoder().decode(BrowserMessage.self, from: data), m.v == 1,
              m.ts > 0, !m.family.isEmpty, m.family.count < 32 else { return nil }
        return m
    }

    public static func observation(from m: BrowserMessage) -> (ActivitySignal, Date)? {
        guard m.type == "tab" || m.type == "focus" else { return nil }
        let tab = BrowserTabInfo(family: m.family.lowercased(), url: m.url, title: m.title.map { String($0.prefix(300)) },
                                 incognito: m.incognito ?? false, audible: m.audible ?? false, windowFocused: m.focused ?? true)
        return (.browserTab(tab), Date(timeIntervalSince1970: m.ts))
    }

    /// Read and remove all inbox files, returning valid messages in timestamp order.
    /// Files are renamed before reading so a concurrently writing host starts a fresh file.
    public static func drain(directory: URL = defaultDirectory, fileManager fm: FileManager = .default) -> [BrowserMessage] {
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [BrowserMessage] = []
        for f in files where f.pathExtension == "jsonl" {
            let claimed = f.appendingPathExtension("draining")
            guard (try? fm.moveItem(at: f, to: claimed)) != nil else { continue }
            if let text = try? String(contentsOf: claimed, encoding: .utf8) {
                out += text.split(separator: "\n").compactMap { parse(line: String($0)) }
            }
            try? fm.removeItem(at: claimed)
        }
        return out.sorted { $0.ts < $1.ts }
    }

    /// Whether the extension has reported recently (for tracking-health indicators).
    public static func lastActivity(directory: URL = defaultDirectory) -> Date? {
        let marker = directory.appendingPathComponent("last-seen")
        return (try? FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate]) as? Date
    }
}
