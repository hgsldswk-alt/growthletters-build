import Foundation
import UserNotifications

actor Reminders {
    static let prefix = "growthletters.open."
    private var revision = 0

    func permission() async throws -> Bool {
        if Launch.uiTesting { return !Launch.args.contains("-notification-denied") }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return try await center.requestAuthorization(options: [.alert, .sound])
        default: return false
        }
    }

    func sync(_ reminders: [UUID: OpeningReminder], entitlement: Entitlement, now: Date = .now) async -> Bool {
        guard !Launch.uiTesting else { return true }
        revision += 1
        let version = revision
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let old = await center.pendingNotificationRequests()
        guard version == revision else { return true }
        let eligible = reminders.filter { _, reminder in
            reminder.enabled && reminder.delivery > now &&
                (Launch.isFree || entitlement.purchasedPro || (entitlement.hasPro(at: now) && reminder.delivery < entitlement.trialEnd))
        }.sorted { $0.value.delivery < $1.value.delivery }.prefix(60)

        let existing = old.filter { $0.identifier.hasPrefix(Self.prefix) }
        let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        let desired = allowed ? Array(eligible) : []
        let keep = Set(desired.map { Self.prefix + $0.key.uuidString })
        center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier).filter { !keep.contains($0) })
        for (id, reminder) in desired {
            guard version == revision else { return true }
            let key = Self.prefix + id.uuidString
            let components = DateComponents(year: reminder.day.year, month: reminder.day.month, day: reminder.day.day, hour: 9)
            if existing.contains(where: { $0.identifier == key && ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents == components }) {
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = L.t("notification.title")
            content.body = L.t("notification.body")
            content.sound = .default
            content.userInfo = ["child": id.uuidString]
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: trigger)) }
            catch { if version == revision { return false } }
        }
        return true
    }
}

final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let opened = Notification.Name("GrowthLetters.OpenReminder")

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["child"] as? String {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.opened, object: id)
            }
        }
        completionHandler()
    }
}
