import AppKit
import AtlasCore

/// Reads the front tab of Chrome, Brave, Edge, Arc, Vivaldi or Safari via Apple Events.
///
/// Works with no extension installed. macOS asks once per browser ("ATLAS wants to control Google Chrome")
/// the first time it runs. It runs only while a supported browser is frontmost: once on activation, then
/// every 10 s to catch tab switches. It stands down while the browser extension is reporting, since the
/// extension is event-driven and also knows when audio is playing.
@MainActor
public final class BrowserScriptProbe {
    private let sink: SignalSink
    private var timer: Timer?
    private var currentBundle: String?
    public var enabled = true
    public var trackIncognito = false
    public private(set) var lastError: String?

    /// bundle id (lowercased) → (family, AppleScript tab expression style)
    static let browsers: [String: (family: String, chromium: Bool)] = [
        "com.google.chrome": ("chrome", true), "com.google.chrome.beta": ("chrome", true), "com.google.chrome.canary": ("chrome", true),
        "com.brave.browser": ("brave", true), "com.microsoft.edgemac": ("edge", true), "com.vivaldi.vivaldi": ("vivaldi", true),
        "company.thebrowser.browser": ("arc", true), "com.apple.safari": ("safari", false),
    ]

    public init(sink: @escaping SignalSink) { self.sink = sink }

    public func frontmostChanged(to bundleID: String?) {
        timer?.invalidate()
        timer = nil
        currentBundle = nil
        guard enabled, let id = bundleID?.lowercased(), Self.browsers[id] != nil else { return }
        currentBundle = bundleID
        probe()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        timer?.tolerance = 2
    }

    private func extensionIsReporting() -> Bool {
        BrowserInbox.lastActivity().map { Date().timeIntervalSince($0) < 120 } ?? false
    }

    private func probe() {
        guard let bundle = currentBundle, let info = Self.browsers[bundle.lowercased()] else { return }
        if info.chromium && extensionIsReporting() { return }
        let script = info.chromium ? """
            tell application id "\(bundle)"
                if (count of windows) is 0 then return ""
                set w to front window
                set m to "normal"
                try
                    set m to mode of w
                end try
                return (URL of active tab of w) & linefeed & (title of active tab of w) & linefeed & m
            end tell
            """ : """
            tell application id "\(bundle)"
                if (count of windows) is 0 then return ""
                set t to current tab of front window
                return (URL of t) & linefeed & (name of t) & linefeed & "normal"
            end tell
            """
        var err: NSDictionary?
        let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue
        if let err {
            // -1743: the user denied Automation permission for this browser.
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            lastError = code == -1743 ? "Automation permission denied for \(info.family)" : "AppleScript error \(code)"
            return
        }
        lastError = nil
        guard let out, !out.isEmpty else { return }
        let parts = out.components(separatedBy: "\n")
        let incognito = parts.count > 2 && parts[2].lowercased().contains("incognito")
        let tab = BrowserTabInfo(family: info.family, url: parts.first,
                                 title: parts.count > 1 ? parts[1] : nil, incognito: incognito)
        sink(.browserTab(tab), Date())
    }

    /// Triggers the macOS Automation consent prompt for a browser (used from onboarding).
    nonisolated public static func requestPermission(bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
        return status == noErr
    }

    nonisolated public static func permissionStatus(bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    }
}
