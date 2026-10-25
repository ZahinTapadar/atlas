import AtlasCore
import Foundation
import ServiceManagement
import UserNotifications

/// Native notifications. Content is lock-screen safe by default: the minimal style says only that a
/// report is ready; the summary style never includes site names or window titles.
public enum NotificationService {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    public static func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public static func post(id: String, title: String, body: String) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.threadIdentifier = "atlas-reports"
        c.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    public static func isQuiet(_ quiet: DailyHours?, at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let quiet else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return quiet.startMinute <= quiet.endMinute ? (m >= quiet.startMinute && m < quiet.endMinute)
                                                    : (m >= quiet.startMinute || m < quiet.endMinute)
    }
}

public enum LaunchAtLogin {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Requires running from a signed .app bundle (see scripts/build-app.sh).
    public static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
