import AtlasCore
import Foundation

// Native-messaging host for the ATLAS browser extension (Chrome/Edge/Brave/Arc/Vivaldi/Firefox).
//
// The browser launches this process when the extension connects and talks to it over stdin/stdout
// using 4-byte little-endian length-prefixed JSON. Each valid message is appended as one line to
// ~/Library/Application Support/ATLAS/BrowserInbox/<pid>.jsonl; the ATLAS app drains that directory.
// This keeps ATLAS free of any listening server and lets tracking survive the app being closed briefly.

let inbox = BrowserInbox.defaultDirectory
try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
let fileURL = inbox.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).jsonl")
let marker = inbox.appendingPathComponent("last-seen")
let stdin = FileHandle.standardInput
let stdout = FileHandle.standardOutput

func readExactly(_ n: Int) -> Data? {
    var data = Data()
    while data.count < n {
        let chunk = stdin.readData(ofLength: n - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

func reply(_ obj: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var len = UInt32(body.count).littleEndian
    stdout.write(Data(bytes: &len, count: 4))
    stdout.write(body)
}

func append(_ line: String) {
    // Re-open each time: the app renames files while draining, so we must not hold a stale handle.
    let data = Data((line + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: fileURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: fileURL)
    }
    FileManager.default.createFile(atPath: marker.path, contents: nil) // touch: health indicator
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path)
}

while let header = readExactly(4) {
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    guard length > 0, length < 1_000_000, let body = readExactly(Int(length)) else { break }
    let line = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
    if let msg = BrowserInbox.parse(line: line) {
        if msg.type == "tab" || msg.type == "focus" { append(line) }
        reply(["ok": true])
    } else {
        reply(["ok": false, "error": "invalid message"])
    }
}
