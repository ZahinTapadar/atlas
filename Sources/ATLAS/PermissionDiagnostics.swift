import AppKit
import ApplicationServices
import AtlasCore
import Security

/// Answers "what does macOS think of *this* app?" from inside the app itself (TCC attributes checks to the
/// responsible process, so running the binary from a terminal would test the terminal instead).
enum PermissionDiagnostics {
    static var fileURL: URL { AtlasStore.defaultDirectory.appendingPathComponent("diagnostics.json") }

    static func report() -> [String: Any] {
        var code: SecCode?
        SecCodeCopySelf([], &code)
        var staticCode: SecStaticCode?
        if let code { SecCodeCopyStaticCode(code, [], &staticCode) }
        var info: CFDictionary?
        if let staticCode { SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) }
        let dict = info as? [String: Any] ?? [:]
        var requirement: SecRequirement?
        var reqText: CFString?
        if let staticCode, SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
            SecRequirementCopyString(requirement, [], &reqText)
        }
        return [
            "date": ISO8601DateFormatter().string(from: Date()),
            "accessibilityTrusted": AXIsProcessTrusted(),
            "bundlePath": Bundle.main.bundlePath,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "teamID": dict[kSecCodeInfoTeamIdentifier as String] as? String ?? "none (ad-hoc)",
            "designatedRequirement": (reqText as String?) ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]
    }

    static func writeAndExit() -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: report(), options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: AtlasStore.defaultDirectory, withIntermediateDirectories: true)
            try? data.write(to: fileURL)
        }
        exit(0)
    }
}
