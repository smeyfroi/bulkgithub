import Foundation
import UserNotifications
import AppKit

/// Posts a local macOS notification when a run that hit retries (or ran long)
/// finishes while the app is in the background — so a user who walked away while
/// it ground through transient errors is told it's done. Local notifications
/// need no entitlement for a non-sandboxed signed app.
@MainActor
enum NotificationService {
    private static var authorizationRequested = false

    /// Ask once, lazily at first run, so the permission prompt appears in context.
    static func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Deliver a completion notification — suppressed when the app is frontmost
    /// (an attentive user doesn't need it). A no-op if the user denied access
    /// (the center silently drops it).
    static func notifyRunComplete(title: String, body: String) {
        guard !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
