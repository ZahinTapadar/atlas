import AppKit
import ApplicationServices
import AtlasCore
import CoreGraphics

public typealias ObservationSink = @MainActor (ActivitySignal, Date) -> Void

/// Foreground app, sleep/wake, display sleep, and lock/unlock via NSWorkspace and distributed
/// notifications. Purely event-driven: no polling.
@MainActor
public final class WorkspaceMonitor {
    private var tokens: [NSObjectProtocol] = []
    private let sink: ObservationSink

    public init(sink: @escaping ObservationSink) { self.sink = sink }

    public static func frontmostApp() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppInfo(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier)
    }

    public func start() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ make: @escaping @Sendable (Notification) -> ActivitySignal?) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Translate first (ActivitySignal is Sendable), then hop onto the main actor we're already on.
                guard let o = make(note) else { return }
                MainActor.assumeIsolated { self?.sink(o, Date()) }
            })
        }
        on(ws, NSWorkspace.didActivateApplicationNotification) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return nil }
            return .appActivated(AppInfo(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier))
        }
        on(ws, NSWorkspace.willSleepNotification) { _ in .systemWillSleep }
        on(ws, NSWorkspace.didWakeNotification) { _ in .systemDidWake }
        on(ws, NSWorkspace.screensDidSleepNotification) { _ in .displaySlept }
        on(ws, NSWorkspace.screensDidWakeNotification) { _ in .displayWoke }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { _ in .screenLocked }   // fast user switching
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { _ in .screenUnlocked }
        let dnc = DistributedNotificationCenter.default()
        on(dnc, Notification.Name("com.apple.screenIsLocked")) { _ in .screenLocked }
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { _ in .screenUnlocked }
    }

    public func stop() {
        for t in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
            DistributedNotificationCenter.default().removeObserver(t)
        }
        tokens.removeAll()
    }
}

/// User-input idleness from the HID system's "seconds since last event" counter (no permission needed,
/// no keystroke contents). macOS has no idle notification, so this uses an adaptive timer: while
/// active it sleeps until the threshold could next be crossed; while idle it checks every few seconds.
@MainActor
public final class IdleMonitor {
    private let sink: ObservationSink
    private var timer: Timer?
    private var isIdle = false
    public var threshold: TimeInterval

    public init(threshold: TimeInterval, sink: @escaping ObservationSink) {
        self.threshold = threshold
        self.sink = sink
    }

    public static func secondsSinceLastInput() -> TimeInterval {
        // ~0 == kCGAnyInputEventType: keyboard, mouse, trackpad, tablet. Contents are never read.
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    public func start() { schedule(after: 1) }
    public func stop() { timer?.invalidate(); timer = nil }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = min(5, delay * 0.1)
    }

    private func check() {
        let idle = Self.secondsSinceLastInput()
        let now = Date()
        if !isIdle && idle >= threshold {
            isIdle = true
            sink(.inputIdle(lastInput: now.addingTimeInterval(-idle)), now)
        } else if isIdle && idle < threshold {
            isIdle = false
            sink(.inputResumed, now)
        }
        schedule(after: isIdle ? 5 : threshold - idle)
    }
}

/// Focused-window titles via the Accessibility API. Optional: without permission the tracker
/// keeps working on app identity alone and records that titles were unavailable.
@MainActor
public final class WindowTitleObserver {
    private let sink: ObservationSink
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var observedPID: pid_t = 0
    public var enabled = true
    public var excludedBundleIDs: Set<String> = []

    public init(sink: @escaping ObservationSink) { self.sink = sink }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security → Accessibility.
    public static func requestTrust() {
        // "AXTrustedCheckOptionPrompt" == kAXTrustedCheckOptionPrompt (the global is not concurrency-safe to reference).
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    public func follow(app: AppInfo?) {
        detach()
        guard let app, let pid = app.pid else { return }
        // Never read titles of excluded apps, not even transiently.
        if !enabled || excludedBundleIDs.contains((app.bundleID ?? "").lowercased()) { return }
        guard Self.isTrusted else {
            sink(.windowTitle(nil, available: false), Date())
            return
        }
        let element = AXUIElementCreateApplication(pid)
        appElement = element
        observedPID = pid
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowTitleObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.emitCurrentTitle() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else {
            sink(.windowTitle(nil, available: false), Date())
            return
        }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, element, kAXTitleChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        emitCurrentTitle()
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        appElement = nil
    }

    private func emitCurrentTitle() {
        guard let appElement else { return }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            sink(.windowTitle(nil, available: true), Date())
            return
        }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        let t = (title as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        sink(.windowTitle(t, available: true), Date())
    }
}
