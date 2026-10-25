import AtlasCore
import Foundation

/// Minimal Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Exposes ATLAS as read-only tools plus `record_checkin`, so Claude can see what you actually did.
struct MCPServer {
    static var tools: [[String: Any]] { [
        [
            "name": "get_activity_summary",
            "description": "Summarize what the user actually did on their Mac in a time range, as tracked by ATLAS: time per category (coding, research, gaming, social media, ...), top apps/sites, focus and context-switch stats, idle/uncertain/untracked time, and optionally a merged timeline. Excluded/private activity is shown only as 'excluded'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": "Start: ISO-8601, 'today' (default), 'yesterday', or relative like '-3h', 'last_90m'."],
                    "to": ["type": "string", "description": "End: ISO-8601, 'now' (default), or relative."],
                    "include_timeline": ["type": "boolean", "description": "Include the chronological timeline (default true)."],
                ],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_current_activity",
            "description": "What the user is doing on their Mac right now (app or site, category, active/idle state) and whether ATLAS is tracking.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "get_recent_checkins",
            "description": "Previous check-in feedback recorded in ATLAS, newest first. Use to stay consistent and notice trends across the day.",
            "inputSchema": ["type": "object", "properties": ["limit": ["type": "integer", "description": "Default 5"]],
                            "additionalProperties": false],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "record_checkin",
            "description": "Save this check-in's feedback into ATLAS so the user sees it in the app's Agent panel.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "verdict": ["type": "string", "enum": ["on_track", "mixed", "off_track", "insufficient_data"]],
                    "feedback": ["type": "string", "description": "The feedback shown to the user (markdown)."],
                ],
                "required": ["verdict", "feedback"],
                "additionalProperties": false,
            ],
        ],
    ] }

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // notifications (e.g. notifications/initialized) need no reply
            switch method {
            case "initialize":
                let version = params["protocolVersion"] as? String ?? "2025-06-18"
                respond(id, ["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                             "serverInfo": ["name": "atlas", "version": "0.2.0"],
                             "instructions": "ATLAS tracks how the user spends time on their Mac. It does not plan; use it to compare what they actually did with their calendar and priorities."])
            case "ping":
                respond(id, [String: Any]())
            case "tools/list":
                respond(id, ["tools": Self.tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let a = params["arguments"] as? [String: Any] ?? [:]
                do {
                    respond(id, ["content": [["type": "text", "text": try await call(name, a)]], "isError": false])
                } catch {
                    respond(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
                }
            default:
                send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
    }

    func call(_ name: String, _ a: [String: Any]) async throws -> String {
        switch name {
        case "get_activity_summary":
            let d = try await digest(from: a["from"] as? String ?? "today", to: a["to"] as? String,
                                     timeline: a["include_timeline"] as? Bool ?? true)
            return json(d)
        case "get_current_activity":
            let d = try await digest(from: "-10m", to: "now", timeline: false)
            return json(["trackerRunning": AnyCodable(d.trackerRunning), "lastRecordedAt": AnyCodable(d.lastRecordedAt),
                         "current": AnyCodable(d.current), "trackingHealth": AnyCodable(d.trackingHealth)])
        case "get_recent_checkins":
            return json(try await readStore().checkins(limit: a["limit"] as? Int ?? 5))
        case "record_checkin":
            guard let feedback = a["feedback"] as? String, !feedback.isEmpty else {
                throw NSError(domain: "atlas", code: 3, userInfo: [NSLocalizedDescriptionKey: "feedback is required"])
            }
            let store = try AtlasStore(path: AtlasStore.defaultPath)
            try await store.saveCheckin(.init(source: "scheduled-checkin", verdict: a["verdict"] as? String, body: feedback))
            return "Saved to ATLAS."
        default:
            throw NSError(domain: "atlas", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unknown tool \(name)"])
        }
    }

    func respond(_ id: Any?, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id!, "result": result]) }

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// Type-erased Encodable for small ad-hoc JSON objects.
struct AnyCodable: Encodable {
    let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ v: T) { encodeFn = v.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
