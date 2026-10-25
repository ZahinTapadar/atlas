import CryptoKit
import Foundation

/// Updates ATLAS from its GitHub releases. A new version is downloaded, checked against the published
/// SHA-256, and its code signature must come from the ATLAS Release certificate pinned below before it
/// replaces the running app. Because every release is signed with that one certificate, macOS keeps
/// Accessibility and Automation grants across updates.
public enum Updater {
    public static let repo = "ZahinTapadar/atlas"

    /// Code requirement every release must satisfy: the ATLAS bundle id, signed by the ATLAS Release certificate.
    public static let releaseRequirement = #"identifier "com.atlas.tracker" and certificate root = H"7d3eed29018c8a73ae6f33dc246d854a65c46a9a""#

    public struct Release: Sendable, Equatable {
        public var version: String
        public var notes: String
        public var dmg: URL
        public var checksum: URL
        public var page: URL
    }

    public struct Failure: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Release builds carry `ATLASUpdateChannel = release` (set by scripts/package-release.sh). Builds made
    /// from source update from their checkout instead.
    public static var isReleaseBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ATLASUpdateChannel") as? String == "release"
    }

    public static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public static func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ATLAS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw Failure(message: "Couldn't read the latest release from GitHub.")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        func asset(_ name: String) -> URL? {
            assets.first { $0["name"] as? String == name }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        guard let dmg = asset("ATLAS-\(version).dmg"), let sum = asset("ATLAS-\(version).dmg.sha256") else {
            throw Failure(message: "The latest release has no disk image yet.")
        }
        return Release(version: version, notes: json["body"] as? String ?? "", dmg: dmg, checksum: sum, page: page)
    }

    /// Numeric dotted-version comparison ("1.10.0" > "1.9.2").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads, verifies and stages the new app next to the current one. Returns the staged bundle.
    public static func stage(_ release: Release, replacing app: URL, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let parent = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw Failure(message: "ATLAS can't write to \(parent.path). Move ATLAS to Applications, or update with Homebrew.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress("Downloading ATLAS \(release.version)…")
        let (tmp, resp) = try await URLSession.shared.download(from: release.dmg)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw Failure(message: "The download failed (\(http.statusCode)).") }
        let dmg = work.appendingPathComponent("ATLAS.dmg")
        try FileManager.default.moveItem(at: tmp, to: dmg)
        let (sumData, _) = try await URLSession.shared.data(from: release.checksum)
        let expected = String(decoding: sumData, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard expected.count == 64, expected.lowercased() == actual else { throw Failure(message: "The download didn't match its checksum, so it wasn't installed.") }

        progress("Checking the new version…")
        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let staged = parent.appendingPathComponent(".ATLAS-\(release.version)-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [mount.appendingPathComponent("ATLAS.app").path, staged.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(releaseRequirement)", staged.path])
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw Failure(message: "The new version isn't signed with the ATLAS release certificate, so it wasn't installed.")
        }
        return staged
    }

    /// Swaps the staged bundle in once this process exits, then opens the new version.
    public static func installOnExit(staged: URL, replacing app: URL) throws {
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        OLD="$2.previous"
        rm -rf "$OLD"
        mv "$2" "$OLD" && mv "$1" "$2" && rm -rf "$OLD" || { [ -d "$2" ] || mv "$OLD" "$2"; }
        open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "atlas-update", staged.path, app.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Failure(message: "\(URL(fileURLWithPath: exe).lastPathComponent) failed: \(s)") }
        return s
    }
}
