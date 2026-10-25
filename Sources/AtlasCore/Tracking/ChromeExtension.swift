import Foundation

/// The bundled Chromium extension ships a fixed public `key` in its manifest, so its ID is stable
/// wherever it is loaded from. That lets ATLAS register its native-messaging helper automatically.
public enum ChromeExtension {
    public static let id = "llolohdkomppidilbbmkmoognfcgoheh"
    public static let hostName = "com.atlas.tracker.nm"

    /// NativeMessagingHosts directories of installed Chromium browsers.
    public static func hostDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support")
        return ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium", "Microsoft Edge",
                "BraveSoftware/Brave-Browser", "Vivaldi", "Arc/User Data"]
            .map { support.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.appendingPathComponent("NativeMessagingHosts") }
    }

    /// Write (or refresh) the host manifest pointing at `hostPath`. Idempotent; returns the directories written.
    @discardableResult
    public static func registerNativeHost(hostPath: String) -> [URL] {
        let manifest: [String: Any] = [
            "name": hostName, "description": "ATLAS activity bridge", "path": hostPath, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(id)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return [] }
        var written: [URL] = []
        for dir in hostDirectories() {
            let file = dir.appendingPathComponent("\(hostName).json")
            if (try? Data(contentsOf: file)) == data { written.append(dir); continue }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? data.write(to: file, options: .atomic)) != nil { written.append(dir) }
        }
        return written
    }
}
