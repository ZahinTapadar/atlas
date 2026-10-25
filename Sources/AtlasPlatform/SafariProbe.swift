import AppKit
import AtlasCore

/// Optional Safari integration via Apple Events (Automation permission, off by default).
/// Safari Web Extensions must ship inside a signed Xcode app container, which a SwiftPM build can't
/// produce, so this is the legitimate alternative: it asks Safari for its front tab only while Safari
/// is frontmost, and macOS shows a consent prompt the first time. Private windows are not reported
/// by Safari's scripting interface.
@MainActor
public final class SafariProbe {
    private let sink: ObservationSink
    private var timer: Timer?
    public var enabled = false

    public init(sink: @escaping ObservationSink) { self.sink = sink }

    public func frontmostChanged(to bundleID: String?) {
        timer?.invalidate()
        timer = nil
        guard enabled, bundleID?.lowercased() == "com.apple.safari" else { return }
        probe()
        // Tab switches inside Safari produce no system notification; check at a modest cadence while frontmost.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        timer?.tolerance = 3
    }

    private func probe() {
        let source = """
        tell application "Safari"
            if (count of windows) is 0 then return ""
            set t to current tab of front window
            return (URL of t) & linefeed & (name of t)
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue, err == nil, !out.isEmpty else { return }
        let parts = out.split(separator: "\n", maxSplits: 1).map(String.init)
        let tab = BrowserTabInfo(family: "safari", url: parts.first, title: parts.count > 1 ? parts[1] : nil)
        sink(.browserTab(tab), Date())
    }
}
